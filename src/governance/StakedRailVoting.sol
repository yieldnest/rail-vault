// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {StakedRailStrategy} from "../core/StakedRailStrategy.sol";
import {RailStakePositionManager} from "../core/RailStakePositionManager.sol";
import {StakedRailSupplyHook} from "./StakedRailSupplyHook.sol";
import {IRailgunVoting, IRailgunVotingSnapshots} from "../railgun/IRailgunVoting.sol";

/**
 * @notice Non-transferable stRAIL locks with a requested-unlock cooldown that forward fractional RAILGUN votes.
 * @dev Upgrade authority belongs to the proxy admin. No arbitrary calls or caller-supplied valuation.
 */
contract StakedRailVoting is ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    //// STORAGE ////

    struct Lock {
        address owner;
        uint256 shares;
        uint256 createdAt;
        uint256 unlockAt; // Zero until unlock is requested.
        bool withdrawn;
    }

    // Preserve declaration order and types across upgrades; append new state after existing fields.
    StakedRailStrategy public stRail;
    RailStakePositionManager public positionManager;
    IRailgunVoting public voting;
    IRailgunVotingSnapshots public snapshots;
    StakedRailSupplyHook public supplyHook;
    uint256 public unlockCooldown;
    uint256 public totalLocked;
    Lock[] public locks;
    mapping(uint256 proposalId => mapping(uint256 lockId => uint256 amount)) public votesUsed;

    //// EVENTS ////

    event Locked(uint256 indexed lockId, address indexed owner, uint256 shares);
    event UnlockRequested(uint256 indexed lockId, address indexed owner, uint256 unlockAt);
    event Withdrawn(uint256 indexed lockId, address indexed owner, uint256 shares);
    event VoteForwarded(uint256 indexed proposalId, uint256 indexed lockId, bool affirmative, uint256 railVotes);

    //// ERRORS ////

    error InvalidConfiguration();
    error InvalidLock();
    error NotOwner();
    error StillLocked();
    error IneligibleLock();
    error VotingClosed();
    error InsufficientVotingPower();

    //// INITIALIZATION ////

    constructor() {
        _disableInitializers();
    }

    function initialize(
        StakedRailStrategy stRail_,
        IRailgunVoting voting_,
        StakedRailSupplyHook supplyHook_,
        uint256 unlockCooldown_
    ) external initializer {
        if (
            address(stRail_) == address(0) || address(voting_) == address(0) || address(supplyHook_) == address(0)
                || unlockCooldown_ == 0
        ) {
            revert InvalidConfiguration();
        }

        __ReentrancyGuard_init();

        stRail = stRail_;
        positionManager = stRail_.positionManager();
        voting = voting_;
        if (voting_.STAKING_CONTRACT() != address(positionManager.staking())) {
            revert InvalidConfiguration();
        }

        snapshots = IRailgunVotingSnapshots(address(positionManager.staking()));
        supplyHook = supplyHook_;
        unlockCooldown = unlockCooldown_;
    }

    //// LOCKING ////

    /**
     * @notice Lock shares indefinitely until the owner requests an unlock.
     * @dev Each deposit is a separate position; top-ups cannot inherit an older position's eligibility.
     */
    function lock(uint256 shares) external nonReentrant returns (uint256 id) {
        if (shares == 0) revert InvalidLock();

        id = locks.length;
        locks.push(Lock(msg.sender, shares, block.timestamp, 0, false));
        totalLocked += shares;

        IERC20(address(stRail)).safeTransferFrom(msg.sender, address(this), shares);

        emit Locked(id, msg.sender, shares);
    }

    /**
     * @notice Stop voting and start the withdrawal cooldown. Requests cannot be cancelled or restarted.
     * @dev Native RAILGUN voting uses historical snapshots, so unstaking does not itself remove eligibility
     * for an already-snapshotted proposal. This escrow deliberately blocks further votes immediately
     * when unlock is requested; votes already cast remain in effect.
     */
    function requestUnlock(uint256 id) external nonReentrant {
        Lock storage position = locks[id];
        if (msg.sender != position.owner) revert NotOwner();
        if (position.withdrawn || position.unlockAt != 0) revert InvalidLock();

        position.unlockAt = block.timestamp + unlockCooldown;

        emit UnlockRequested(id, msg.sender, position.unlockAt);
    }

    /**
     * @notice Return shares after a requested unlock matures, even if voting is disabled upstream.
     */
    function withdraw(uint256 id) external nonReentrant {
        Lock storage position = locks[id];
        if (msg.sender != position.owner) revert NotOwner();
        if (position.withdrawn) revert InvalidLock();
        if (position.unlockAt == 0 || block.timestamp < position.unlockAt) revert StillLocked();

        position.withdrawn = true;
        totalLocked -= position.shares;

        IERC20(address(stRail)).safeTransfer(position.owner, position.shares);

        emit Withdrawn(id, position.owner, position.shares);
    }

    //// VOTING ////

    /**
     * @notice Maximum cumulative RAIL votes for this lock and proposal.
     * @dev Historical active backing per share caps live RAIL valuation. Donations cannot buy
     * more historical votes; unlocked/nonparticipating stRAIL does not amplify participants.
     */
    function votingPower(uint256 id, uint256 proposalId, uint256 hint) public view returns (uint256) {
        Lock storage position = locks[id];
        (,,,, uint256 calledAt,,,,, uint256 interval) = voting.proposals(proposalId);
        uint256 cutoff = snapshots.DEPLOY_TIME() + interval * snapshots.SNAPSHOT_INTERVAL();
        if (
            calledAt == 0 || cutoff > block.timestamp || position.withdrawn || position.createdAt >= cutoff
                || position.unlockAt != 0
        ) return 0;

        uint256 supply = supplyHook.totalSupplyBefore(cutoff);
        if (supply == 0) return 0;

        uint256 eligibleRail = snapshots.accountSnapshotAt(address(positionManager), interval, hint).votingPower;
        uint256 historicalAllocation = Math.mulDiv(position.shares, eligibleRail, supply);
        return Math.min(historicalAllocation, stRail.convertToAssets(position.shares));
    }

    /**
     * @notice Cast an irreversible amount of this lock's RAIL voting entitlement.
     * @param amount RAIL base units, not stRAIL shares. Partial YES/NO votes are supported.
     */
    function vote(uint256 id, uint256 proposalId, uint256 amount, bool affirmative, uint256 hint)
        external
        nonReentrant
    {
        Lock storage position = locks[id];
        if (msg.sender != position.owner) revert NotOwner();
        (,,,, uint256 calledAt,,,,,) = voting.proposals(proposalId);
        uint256 end = affirmative ? voting.VOTING_YAY_END_OFFSET() : voting.VOTING_NAY_END_OFFSET();
        if (
            calledAt == 0 || block.timestamp <= calledAt + voting.VOTING_START_OFFSET()
                || block.timestamp >= calledAt + end
        ) revert VotingClosed();

        uint256 power = votingPower(id, proposalId, hint);
        if (power == 0) revert IneligibleLock();

        uint256 used = votesUsed[proposalId][id];
        if (amount == 0 || used + amount > power) revert InsufficientVotingPower();

        votesUsed[proposalId][id] = used + amount;

        voting.vote(proposalId, amount, affirmative, address(positionManager), hint);

        emit VoteForwarded(proposalId, id, affirmative, amount);
    }
}
