// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRailgunStaking} from "../railgun/IRailgunStaking.sol";
import {DoubleEndedQueue} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import {RailReceiptToken} from "./RailReceiptToken.sol";

contract RailStakePositionManager is AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    string public constant RAIL_STAKE_POSITION_MANAGER_VERSION = "0.1.0";

    bytes32 public constant TOKEN_WITHDRAWER_ROLE = keccak256("TOKEN_WITHDRAWER_ROLE");
    bytes32 public constant CREATOR_ROLE = keccak256("CREATOR_ROLE");
    bytes32 public constant QUEUER_ROLE = keccak256("QUEUER_ROLE");
    bytes32 public constant CLAIMER_ROLE = keccak256("CLAIMER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public rail;
    IRailgunStaking public staking;

    DoubleEndedQueue.Bytes32Deque private activeStakes;
    RailReceiptToken public activeRail;
    RailReceiptToken public unlockedRail;

    event PositionCreated(uint256 indexed stakeId, uint256 principal);
    event PositionQueued(uint256 indexed stakeId, uint256 principal, uint256 locktime);
    event PositionClaimed(uint256 indexed stakeId, uint256 principal, address indexed receiver);
    event TokenTransferred(address indexed token, address indexed receiver, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    /// @param proxyAdminOwner Governance owner of both receipt-token ProxyAdmins, not the setup caller.
    function initialize(address admin, IERC20 railToken, IRailgunStaking stakingContract, address proxyAdminOwner)
        external
        initializer
    {
        if (
            admin == address(0) || address(railToken) == address(0) || address(stakingContract) == address(0)
                || proxyAdminOwner == address(0)
        ) revert ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        rail = railToken;
        staking = stakingContract;
        uint8 decimals = IERC20Metadata(address(railToken)).decimals();
        address implementation = address(new RailReceiptToken());
        activeRail = RailReceiptToken(
            address(
                new TransparentUpgradeableProxy(
                    implementation,
                    proxyAdminOwner,
                    abi.encodeCall(RailReceiptToken.initialize, ("Active RAIL", "aRAIL", decimals, address(this)))
                )
            )
        );
        unlockedRail = RailReceiptToken(
            address(
                new TransparentUpgradeableProxy(
                    implementation,
                    proxyAdminOwner,
                    abi.encodeCall(RailReceiptToken.initialize, ("Unlocked RAIL", "uRAIL", decimals, address(this)))
                )
            )
        );
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function createPosition(uint256 amount)
        external
        onlyRole(CREATOR_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 stakeId)
    {
        rail.safeTransferFrom(msg.sender, address(this), amount);
        rail.forceApprove(address(staking), amount);
        stakeId = staking.stake(amount);
        activeStakes.pushBack(bytes32(stakeId));
        activeRail.mint(msg.sender, amount);
        emit PositionCreated(stakeId, amount);
    }

    function queuePosition() external onlyRole(QUEUER_ROLE) whenNotPaused nonReentrant returns (uint256) {
        uint256 stakeId = uint256(activeStakes.popFront());
        (uint256 principal, uint256 locktime, uint256 claimedTime) = _readPosition(stakeId);
        if (!isActivePosition(locktime, claimedTime)) revert InvalidPositionStatus();

        activeRail.burn(msg.sender, principal);
        staking.unlock(stakeId);
        (,,, locktime,) = staking.stakes(address(this), stakeId);

        unlockedRail.mint(msg.sender, principal);
        emit PositionQueued(stakeId, principal, locktime);
        return principal;
    }

    function claimPosition(uint256 stakeId, address receiver)
        public
        onlyRole(CLAIMER_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 amount)
    {
        uint256 locktime;
        uint256 claimedTime;
        (amount, locktime, claimedTime) = _readPosition(stakeId);
        if (!isQueuedPosition(locktime, claimedTime)) revert InvalidPositionStatus();
        if (!isClaimablePosition(locktime, claimedTime)) revert PositionNotMatured();

        unlockedRail.burn(msg.sender, amount);
        staking.claim(stakeId);
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

    /// @notice Transfers any ERC-20 held by the manager; reward policy belongs to the authorized processor.
    /// @dev Principal is held in staking between calls. The shared lock protects principal in transit.
    function transferToken(IERC20 token, address receiver, uint256 amount)
        external
        onlyRole(TOKEN_WITHDRAWER_ROLE)
        nonReentrant
    {
        if (address(token) == address(0) || receiver == address(0)) {
            revert ZeroAddress();
        }
        token.safeTransfer(receiver, amount);
        emit TokenTransferred(address(token), receiver, amount);
    }

    function activePositionCount() external view returns (uint256) {
        return activeStakes.length();
    }

    function activeStakeIdsList() external view returns (uint256[] memory ids) {
        uint256 count = activeStakes.length();
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            ids[i] = uint256(activeStakes.at(i));
        }
    }

    function activeStakeHead() external view returns (uint256) {
        return uint256(activeStakes.front());
    }

    function activeStakeTail() external view returns (uint256) {
        return uint256(activeStakes.back());
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
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
