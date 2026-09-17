// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRailgunGovernorRewards} from "./IRailgunGovernorRewards.sol";
import {IRailgunStaking} from "./IRailgunStaking.sol";

contract RailStakePositionManager is AccessControl, Pausable {
    using SafeERC20 for IERC20;

    enum PositionStatus {
        NONE,
        ACTIVE,
        UNSTAKING,
        CLAIMABLE,
        CLAIMED
    }

    struct Position {
        uint256 stakeId;
        uint256 principal;
        uint64 queuedAt;
        PositionStatus status;
    }

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    IERC20 public immutable rail;
    IRailgunStaking public immutable staking;
    address public strategy;
    address public exitSystem;

    mapping(uint256 => Position) public positions;
    uint256[] private activeStakeIds;
    uint256[] private queuedStakeIds;
    uint256 public activePrincipal;
    uint256 public queuedPrincipal;

    event ExitSystemSet(address indexed exitSystem);
    event PositionCreated(uint256 indexed stakeId, uint256 principal);
    event PositionQueued(uint256 indexed stakeId, uint256 principal, uint256 locktime);
    event PositionClaimed(uint256 indexed stakeId, uint256 principal, address indexed receiver);
    event RewardsClaimed(address indexed rewards, address indexed receiver, address indexed token, uint256 amount);

    constructor(address admin, IERC20 railToken, IRailgunStaking stakingContract) {
        rail = railToken;
        staking = stakingContract;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    modifier onlyStrategy() {
        if (msg.sender != strategy) revert OnlyStrategy();
        _;
    }

    function setExitSystem(address exitSystemAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (exitSystemAddress == address(0)) revert ZeroAddress();
        exitSystem = exitSystemAddress;
        emit ExitSystemSet(exitSystemAddress);
    }

    function setStrategy(address strategyAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (strategyAddress == address(0)) revert ZeroAddress();
        if (strategy != address(0)) revert StrategyAlreadySet();
        strategy = strategyAddress;
    }

    function createPosition(uint256 amount) external onlyStrategy whenNotPaused returns (uint256 stakeId) {
        rail.forceApprove(address(staking), amount);
        stakeId = staking.stake(amount);
        positions[stakeId] =
            Position({stakeId: stakeId, principal: amount, queuedAt: 0, status: PositionStatus.ACTIVE});
        activeStakeIds.push(stakeId);
        activePrincipal += amount;
        emit PositionCreated(stakeId, amount);
    }

    function queuePosition(uint256 stakeId) external onlyRole(KEEPER_ROLE) whenNotPaused returns (uint256 qRailMinted) {
        Position storage position = positions[stakeId];
        if (position.status != PositionStatus.ACTIVE) revert InvalidPositionStatus();
        uint256 principal;
        uint256 claimedTime;
        (, principal,,, claimedTime) = staking.stakes(address(this), stakeId);
        if (claimedTime != 0 || principal != position.principal) revert ExternalPositionMismatch();

        staking.unlock(stakeId);
        uint256 locktime;
        (,,, locktime,) = staking.stakes(address(this), stakeId);

        _removeStakeId(activeStakeIds, stakeId);
        queuedStakeIds.push(stakeId);
        position.queuedAt = uint64(block.timestamp);
        position.status = block.timestamp > locktime ? PositionStatus.CLAIMABLE : PositionStatus.UNSTAKING;
        activePrincipal -= principal;
        queuedPrincipal += principal;
        emit PositionQueued(stakeId, principal, locktime);
        return principal;
    }

    function claimPosition(uint256 stakeId, address receiver) public onlyRole(KEEPER_ROLE) returns (uint256 amount) {
        Position storage position = positions[stakeId];
        if (position.status != PositionStatus.UNSTAKING && position.status != PositionStatus.CLAIMABLE) {
            revert InvalidPositionStatus();
        }
        uint256 locktime;
        uint256 claimedTime;
        (, amount,, locktime, claimedTime) = staking.stakes(address(this), stakeId);
        if (claimedTime != 0 || amount != position.principal) revert ExternalPositionMismatch();
        if (locktime == 0 || block.timestamp <= locktime) revert PositionNotMatured();

        staking.claim(stakeId);
        _removeStakeId(queuedStakeIds, stakeId);
        queuedPrincipal -= amount;
        position.status = PositionStatus.CLAIMED;
        rail.safeTransfer(receiver, amount);

        emit PositionClaimed(stakeId, amount, receiver);
    }

    function claimMaturedPositions(uint256[] calldata stakeIds, address receiver)
        external
        onlyRole(KEEPER_ROLE)
        returns (uint256 totalClaimed)
    {
        for (uint256 i = 0; i < stakeIds.length; i++) {
            totalClaimed += claimPosition(stakeIds[i], receiver);
        }
    }

    function claimRewards(
        IRailgunGovernorRewards rewards,
        IERC20[] calldata tokens,
        uint256 startingInterval,
        uint256 endingInterval,
        uint256[] calldata hints,
        address receiver
    ) external onlyRole(KEEPER_ROLE) returns (uint256[] memory claimed) {
        if (address(rewards) == address(0) || receiver == address(0)) revert ZeroAddress();
        claimed = new uint256[](tokens.length);
        uint256[] memory balancesBefore = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            balancesBefore[i] = tokens[i].balanceOf(address(this));
        }

        rewards.claim(tokens, address(this), startingInterval, endingInterval, hints);

        for (uint256 i = 0; i < tokens.length; i++) {
            claimed[i] = tokens[i].balanceOf(address(this)) - balancesBefore[i];
            if (claimed[i] != 0) {
                tokens[i].safeTransfer(receiver, claimed[i]);
                emit RewardsClaimed(address(rewards), receiver, address(tokens[i]), claimed[i]);
            }
        }
    }

    function refreshPositionStatus(uint256 stakeId) external {
        Position storage position = positions[stakeId];
        if (position.status != PositionStatus.UNSTAKING) return;
        uint256 locktime;
        (,,, locktime,) = staking.stakes(address(this), stakeId);
        if (locktime != 0 && block.timestamp > locktime) {
            position.status = PositionStatus.CLAIMABLE;
        }
    }

    function activePositionCount() external view returns (uint256) {
        return activeStakeIds.length;
    }

    function queuedPositionCount() external view returns (uint256) {
        return queuedStakeIds.length;
    }

    function activeStakeIdsList() external view returns (uint256[] memory) {
        return activeStakeIds;
    }

    function queuedStakeIdsList() external view returns (uint256[] memory) {
        return queuedStakeIds;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _removeStakeId(uint256[] storage values, uint256 stakeId) internal {
        for (uint256 i = 0; i < values.length; i++) {
            if (values[i] == stakeId) {
                values[i] = values[values.length - 1];
                values.pop();
                return;
            }
        }
        revert UnknownStakeId();
    }

    error OnlyStrategy();
    error ZeroAddress();
    error StrategyAlreadySet();
    error UnknownStakeId();
    error InvalidPositionStatus();
    error ExternalPositionMismatch();
    error PositionNotMatured();
}
