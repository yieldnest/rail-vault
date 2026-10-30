// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RailSystemFixture} from "../utils/RailSystemFixture.sol";
import {MockRailgunVoting} from "../mocks/MockRailgunVoting.sol";
import {StakedRailVoting} from "../../src/governance/StakedRailVoting.sol";
import {IRailgunVoting, IRailgunVotingSnapshots} from "../../src/railgun/IRailgunVoting.sol";

contract StakedRailVotingTest is RailSystemFixture {
    StakedRailVoting internal escrow;
    MockRailgunVoting internal voting;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal aliceLock;
    uint256 internal bobLock;
    uint256 internal cutoff;

    function setUp() public {
        vm.warp(100 days);
        _deploySystem();
        voting = new MockRailgunVoting(address(staking));
        escrow = new StakedRailVoting(d.strategy, IRailgunVoting(address(voting)), 7 days);
        d.manager.setVotingKey(IRailgunVoting(address(voting)), address(escrow));
        _deposit(alice, 3000 ether);
        _deposit(bob, 7000 ether);
        d.processor.rebalanceStaking(10);
        aliceLock = _lock(alice, 3000 ether, 10 days);
        bobLock = _lock(bob, 7000 ether, 10 days);
        cutoff = block.timestamp + 1 days;
        vm.mockCall(
            address(staking),
            abi.encodeWithSelector(IRailgunVotingSnapshots.DEPLOY_TIME.selector),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            address(staking),
            abi.encodeWithSelector(IRailgunVotingSnapshots.SNAPSHOT_INTERVAL.selector),
            abi.encode(uint256(1 days))
        );
        _snapshot(10_000 ether);
        voting.prepare(1, cutoff + 1 hours, cutoff / 1 days);
        voting.prepare(2, cutoff + 1 hours, cutoff / 1 days);
        vm.warp(cutoff + 2 days + 1 hours + 1);
    }

    function _snapshot(uint256 power) internal {
        vm.mockCall(
            address(staking),
            abi.encodeWithSelector(IRailgunVotingSnapshots.accountSnapshotAt.selector),
            abi.encode(IRailgunVotingSnapshots.AccountSnapshot(cutoff / 1 days, power))
        );
    }

    function _lock(address owner, uint256 shares, uint256 duration) internal returns (uint256 id) {
        vm.startPrank(owner);
        d.strategy.approve(address(escrow), shares);
        id = escrow.lock(shares, duration);
        vm.stopPrank();
    }

    function testProportionalVotesSplitDirectionsAndIndependentProposals() external {
        assertEq(escrow.votingPower(aliceLock, 1, 0), 3000 ether);
        vm.startPrank(alice);
        escrow.vote(aliceLock, 1, 1000 ether, true, 0);
        escrow.vote(aliceLock, 1, 2000 ether, false, 0);
        escrow.vote(aliceLock, 2, 3000 ether, true, 0);
        vm.expectRevert(StakedRailVoting.InsufficientVotingPower.selector);
        escrow.vote(aliceLock, 1, 1, true, 0);
        vm.stopPrank();
        vm.prank(bob);
        escrow.vote(bobLock, 1, 7000 ether, false, 0);
        (,,,,,, uint256 yes, uint256 no,,) = voting.proposals(1);
        assertEq(yes, 1000 ether);
        assertEq(no, 9000 ether);
        assertEq(voting.getVotes(1, address(d.manager)), 10_000 ether);
        assertEq(escrow.totalLocked(), 10_000 ether);
    }

    function testOnlyLockOwnerCanVoteOrWithdraw() external {
        vm.expectRevert(StakedRailVoting.NotOwner.selector);
        escrow.vote(aliceLock, 1, 1, true, 0);
        vm.expectRevert(StakedRailVoting.NotOwner.selector);
        escrow.withdraw(aliceLock);
    }

    function testHistoricalSupplyUsesStateStrictlyBeforeCutoff() external {
        assertEq(d.strategy.totalSupplyBefore(cutoff), 10_000 ether);
        _deposit(alice, 1000 ether);
        d.strategy.checkpointTotalSupply();
        assertEq(d.strategy.totalSupplyBefore(cutoff), 10_000 ether);
        // A checkpoint at this timestamp is excluded until time advances.
        assertEq(d.strategy.totalSupplyBefore(block.timestamp), 10_000 ether);
        vm.warp(block.timestamp + 1);
        assertEq(d.strategy.totalSupplyBefore(block.timestamp), 11_000 ether);
    }

    function testExpiredWithdrawnSharesCannotBeRelockedToReuseOldVotes() external {
        vm.warp(110 days);
        vm.prank(alice);
        escrow.withdraw(aliceLock);
        uint256 newLock = _lock(alice, 3000 ether, 10 days);
        assertEq(escrow.votingPower(newLock, 1, 0), 0);
        assertEq(escrow.votingPower(aliceLock, 1, 0), 0);
    }

    function testLateDepositCannotVoteAndDoesNotDiluteHistoricalAllocation() external {
        uint256 shares = _deposit(alice, 10_000 ether);
        uint256 late = _lock(alice, shares, 10 days);
        assertEq(escrow.votingPower(late, 1, 0), 0);
        assertEq(escrow.votingPower(aliceLock, 1, 0), 3000 ether);
        vm.prank(alice);
        vm.expectRevert(StakedRailVoting.IneligibleLock.selector);
        escrow.vote(late, 1, 1, true, 0);
    }

    function testLockMustCoverFinalNoVotingDeadline() external {
        // A later proposal starts before expiry but ends after the existing locks expire.
        voting.prepare(3, cutoff + 4 days, cutoff / 1 days);
        assertEq(escrow.votingPower(aliceLock, 3, 0), 0);
    }

    function testWithdrawOnlyAtExpiryAndNoDoubleWithdrawal() external {
        vm.startPrank(alice);
        vm.expectRevert(StakedRailVoting.StillLocked.selector);
        escrow.withdraw(aliceLock);
        vm.warp(110 days);
        escrow.withdraw(aliceLock);
        assertEq(d.strategy.balanceOf(alice), 3000 ether);
        assertEq(escrow.totalLocked(), 7000 ether);
        vm.expectRevert(StakedRailVoting.InvalidLock.selector);
        escrow.withdraw(aliceLock);
        vm.stopPrank();
        assertEq(escrow.votingPower(aliceLock, 1, 0), 0);
    }

    function testUpstreamFailureRollsBackUsageAndDoesNotBlockWithdrawal() external {
        d.manager.setVotingKey(IRailgunVoting(address(voting)), address(0));
        vm.prank(alice);
        vm.expectRevert(bytes("not voting key"));
        escrow.vote(aliceLock, 1, 1000 ether, true, 0);
        assertEq(escrow.votesUsed(1, aliceLock), 0);
        vm.warp(110 days);
        vm.prank(alice);
        escrow.withdraw(aliceLock);
        assertEq(d.strategy.balanceOf(alice), 3000 ether);
    }

    function testActiveBackingCapAndDonationCannotIncreaseVotes() external {
        _snapshot(8000 ether);
        assertEq(escrow.votingPower(aliceLock, 1, 0), 2400 ether);
        rail.mint(address(d.strategy), 100_000 ether);
        assertEq(escrow.votingPower(aliceLock, 1, 0), 2400 ether);
    }

    function testAppreciatedSharesCarryMoreThanOneRailVotePerShare() external {
        vm.warp(200 days);
        _deploySystem();
        voting = new MockRailgunVoting(address(staking));
        escrow = new StakedRailVoting(d.strategy, IRailgunVoting(address(voting)), 7 days);
        d.manager.setVotingKey(IRailgunVoting(address(voting)), address(escrow));
        _deposit(alice, 1000 ether);
        rail.mint(address(d.strategy), 1000 ether);
        uint256 bobShares = _deposit(bob, 1000 ether);
        assertEq(bobShares, 500 ether);
        d.processor.rebalanceStaking(3);
        uint256 a = _lock(alice, 1000 ether, 10 days);
        uint256 b = _lock(bob, bobShares, 10 days);
        cutoff = block.timestamp + 1 days;
        vm.mockCall(
            address(staking),
            abi.encodeWithSelector(IRailgunVotingSnapshots.DEPLOY_TIME.selector),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            address(staking),
            abi.encodeWithSelector(IRailgunVotingSnapshots.SNAPSHOT_INTERVAL.selector),
            abi.encode(uint256(1 days))
        );
        _snapshot(3000 ether);
        voting.prepare(1, cutoff + 1 hours, cutoff / 1 days);
        vm.warp(cutoff + 2 days + 1 hours + 1);
        uint256 aPower = escrow.votingPower(a, 1, 0);
        uint256 bPower = escrow.votingPower(b, 1, 0);
        assertEq(aPower, 2000 ether - 1);
        assertEq(bPower, 1000 ether - 1);
        vm.prank(alice);
        escrow.vote(a, 1, aPower, true, 0);
        vm.prank(bob);
        escrow.vote(b, 1, bPower, false, 0);
        assertEq(voting.getVotes(1, address(d.manager)), 3000 ether - 2);
    }

    function testCurrentValuationCanReduceButNotExpandHistoricalBudget() external {
        // Simulate a backing loss through the valuation boundary.
        vm.mockCall(
            address(d.strategy),
            abi.encodeWithSignature("convertToAssets(uint256)", 3000 ether),
            abi.encode(uint256(1500 ether))
        );
        assertEq(escrow.votingPower(aliceLock, 1, 0), 1500 ether);
        vm.prank(alice);
        vm.expectRevert(StakedRailVoting.InsufficientVotingPower.selector);
        escrow.vote(aliceLock, 1, 1500 ether + 1, true, 0);
    }

    function testVotingWindowAndNoOnlyVetoPeriod() external {
        vm.warp(cutoff + 1 hours + 2 days);
        vm.prank(alice);
        vm.expectRevert(StakedRailVoting.VotingClosed.selector);
        escrow.vote(aliceLock, 1, 1, true, 0);
        vm.warp(cutoff + 1 hours + 5 days);
        vm.startPrank(alice);
        vm.expectRevert(StakedRailVoting.VotingClosed.selector);
        escrow.vote(aliceLock, 1, 1, true, 0);
        escrow.vote(aliceLock, 1, 1, false, 0);
        vm.warp(cutoff + 1 hours + 6 days);
        vm.expectRevert(StakedRailVoting.VotingClosed.selector);
        escrow.vote(aliceLock, 1, 1, false, 0);
        vm.stopPrank();
    }

    function testInvalidLocksAndConfiguration() external {
        vm.expectRevert(StakedRailVoting.InvalidLock.selector);
        escrow.lock(0, 7 days);
        vm.expectRevert(StakedRailVoting.InvalidLock.selector);
        escrow.lock(1, 7 days - 1);
        vm.expectRevert(StakedRailVoting.InvalidConfiguration.selector);
        new StakedRailVoting(d.strategy, IRailgunVoting(address(voting)), 0);
        MockRailgunVoting wrong = new MockRailgunVoting(address(0xBEEF));
        vm.expectRevert();
        d.manager.setVotingKey(IRailgunVoting(address(wrong)), address(escrow));
        vm.prank(alice);
        vm.expectRevert();
        d.manager.setVotingKey(IRailgunVoting(address(voting)), alice);
    }

    function testFuzzSplitVotesCannotExceedAllocation(uint256 first) external {
        first = bound(first, 1, 3000 ether - 1);
        vm.startPrank(alice);
        escrow.vote(aliceLock, 1, first, true, 0);
        escrow.vote(aliceLock, 1, 3000 ether - first, false, 0);
        vm.expectRevert(StakedRailVoting.InsufficientVotingPower.selector);
        escrow.vote(aliceLock, 1, 1, false, 0);
        vm.stopPrank();
    }
}
