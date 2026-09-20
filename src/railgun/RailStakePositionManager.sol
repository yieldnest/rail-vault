// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRailgunGovernorRewards} from "./IRailgunGovernorRewards.sol";
import {IRailgunStaking} from "./IRailgunStaking.sol";
import {LinkedListUInt256} from "../lib/LinkedListUInt256.sol";

contract RailStakePositionManager is AccessControl, Pausable {
    using SafeERC20 for IERC20;
    using LinkedListUInt256 for LinkedListUInt256.List;

    string public constant RAIL_STAKE_POSITION_MANAGER_VERSION = "0.1.0";

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant CREATOR_ROLE = keccak256("CREATOR_ROLE");
    bytes32 public constant QUEUER_ROLE = keccak256("QUEUER_ROLE");
    bytes32 public constant CLAIMER_ROLE = keccak256("CLAIMER_ROLE");

    IERC20 public immutable rail;
    IRailgunStaking public immutable staking;

    // Stake ID zero is valid, so use an explicit end-of-list sentinel.
    uint256 public constant NO_STAKE_ID = LinkedListUInt256.NO_STAKE_ID;
    LinkedListUInt256.List private activeStakes;
    uint256 public activePrincipal;
    uint256 public queuedPrincipal;

    event PositionCreated(uint256 indexed stakeId, uint256 principal);
    event PositionQueued(uint256 indexed stakeId, uint256 principal, uint256 locktime);
    event PositionClaimed(uint256 indexed stakeId, uint256 principal, address indexed receiver);
    event RewardsClaimed(address indexed rewards, address indexed receiver, address indexed token, uint256 amount);

    constructor(address admin, IERC20 railToken, IRailgunStaking stakingContract) {
        rail = railToken;
        staking = stakingContract;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function createPosition(uint256 amount) external onlyRole(CREATOR_ROLE) whenNotPaused returns (uint256 stakeId) {
        rail.forceApprove(address(staking), amount);
        stakeId = staking.stake(amount);
        activeStakes.add(stakeId);
        activePrincipal += amount;
        emit PositionCreated(stakeId, amount);
    }

    function queuePosition(uint256 stakeId) external onlyRole(QUEUER_ROLE) whenNotPaused returns (uint256 qRailMinted) {
        (uint256 principal, uint256 locktime, uint256 claimedTime) = _readPosition(stakeId);
        if (!isActivePosition(locktime, claimedTime)) revert InvalidPositionStatus();

        staking.unlock(stakeId);
        (,,, locktime,) = staking.stakes(address(this), stakeId);

        activeStakes.remove(stakeId);
        activePrincipal -= principal;
        queuedPrincipal += principal;
        emit PositionQueued(stakeId, principal, locktime);
        return principal;
    }

    function claimPosition(uint256 stakeId, address receiver) public onlyRole(CLAIMER_ROLE) returns (uint256 amount) {
        uint256 locktime;
        uint256 claimedTime;
        (amount, locktime, claimedTime) = _readPosition(stakeId);
        if (!isQueuedPosition(locktime, claimedTime)) revert InvalidPositionStatus();
        if (!isClaimablePosition(locktime, claimedTime)) revert PositionNotMatured();

        staking.claim(stakeId);
        queuedPrincipal -= amount;
        rail.safeTransfer(receiver, amount);

        emit PositionClaimed(stakeId, amount, receiver);
    }

    function claimMaturedPositions(uint256[] calldata stakeIds, address receiver)
        external
        onlyRole(CLAIMER_ROLE)
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

    function activePositionCount() external view returns (uint256) {
        return activeStakes.count;
    }

    function activeStakeIdsList() external view returns (uint256[] memory ids) {
        return activeStakes.toArray();
    }

    function activeStakeHead() external view returns (uint256) {
        return activeStakes.head();
    }

    function activeStakeTail() external view returns (uint256) {
        return activeStakes.tail();
    }

    function nextActiveStakeId(uint256 stakeId) external view returns (uint256) {
        return activeStakes.next[stakeId];
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _readPosition(uint256 stakeId)
        internal
        view
        returns (uint256 principal, uint256 locktime, uint256 claimedTime)
    {
        (, principal,, locktime, claimedTime) = staking.stakes(address(this), stakeId);
    }

    function isActivePosition(uint256 locktime, uint256 claimedTime) public pure returns (bool) {
        return claimedTime == 0 && locktime == 0;
    }

    function isQueuedPosition(uint256 locktime, uint256 claimedTime) public pure returns (bool) {
        return claimedTime == 0 && locktime != 0;
    }

    function isClaimablePosition(uint256 locktime, uint256 claimedTime) public view returns (bool) {
        return isQueuedPosition(locktime, claimedTime) && block.timestamp > locktime;
    }

    error ZeroAddress();
    error InvalidPositionStatus();
    error PositionNotMatured();
}
