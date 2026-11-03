// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {MockHookRouter} from "../mocks/MockHookRouter.sol";
import {RailSystemFixture} from "../utils/RailSystemFixture.sol";
import {MockRailgunVoting} from "../mocks/MockRailgunVoting.sol";
import {StakedRailVoting} from "../../src/governance/StakedRailVoting.sol";
import {IRailgunVoting, IRailgunVotingSnapshots} from "../../src/railgun/IRailgunVoting.sol";

import {StakedRailSupplyHook} from "../../src/governance/StakedRailSupplyHook.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IVault} from "@yieldnest-vault/interface/IVault.sol";

contract StakedRailVotingTest is RailSystemFixture {
    StakedRailVoting internal escrow;
    StakedRailSupplyHook internal hook;
    MockRailgunVoting internal voting;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal aliceLock;
    uint256 internal bobLock;
    uint256 internal cutoff;

    function setUp() public {
        vm.warp(100 days);
        _deploySystem();
        hook = StakedRailSupplyHook(
            address(
                new TransparentUpgradeableProxy(
                    address(new StakedRailSupplyHook()),
                    address(this),
                    abi.encodeCall(StakedRailSupplyHook.initialize, (IVault(address(d.strategy))))
                )
            )
        );
        d.strategy.grantRole(d.strategy.HOOKS_MANAGER_ROLE(), address(this));
        d.strategy.setHooks(address(new MockHookRouter(IVault(address(d.strategy)), hook)));
        hook.checkpoint();
        voting = new MockRailgunVoting(address(staking));
        escrow = StakedRailVoting(
            address(
                new TransparentUpgradeableProxy(
                    address(new StakedRailVoting()),
                    address(this),
                    abi.encodeCall(
                        StakedRailVoting.initialize, (d.strategy, IRailgunVoting(address(voting)), hook, 7 days)
                    )
                )
            )
        );
        d.manager.setVotingKey(IRailgunVoting(address(voting)), address(escrow));
        _deposit(alice, 3000 ether);
        _deposit(bob, 7000 ether);
        d.processor.rebalanceStaking(10);
        aliceLock = _lock(alice, 3000 ether);
        bobLock = _lock(bob, 7000 ether);
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

    function _lock(address owner, uint256 shares) internal returns (uint256 id) {
        vm.startPrank(owner);
        d.strategy.approve(address(escrow), shares);
        id = escrow.lock(shares);
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

    function testSupplyHookUpgradePreservesVotingEntitlementThroughRouter() external {
        vm.prank(alice);
        escrow.vote(aliceLock, 1, 1000 ether, true, 0);
        address router = address(d.strategy.hooks());
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(vm.load(address(hook), slot)))));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(hook)), address(new StakedRailSupplyHook()), "");
        assertEq(address(escrow.supplyHook()), address(hook));
        assertEq(address(d.strategy.hooks()), router);
        assertEq(escrow.votingPower(aliceLock, 1, 0), 3000 ether);
        assertEq(escrow.votesUsed(1, aliceLock), 1000 ether);
        _deposit(bob, 100 ether);
        vm.warp(block.timestamp + 1);
        assertEq(hook.totalSupplyBefore(block.timestamp), 10_100 ether);
        vm.startPrank(alice);
        escrow.vote(aliceLock, 1, 2000 ether, false, 0);
        vm.expectRevert(StakedRailVoting.InsufficientVotingPower.selector);
        escrow.vote(aliceLock, 1, 1, true, 0);
        vm.stopPrank();
    }

    function _escrowAdmin() internal view returns (ProxyAdmin) {
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        return ProxyAdmin(address(uint160(uint256(vm.load(address(escrow), slot)))));
    }

    function _lockHash(uint256 id) internal view returns (bytes32) {
        (address owner, uint256 shares, uint256 created, uint256 unlock, uint256 end, bool withdrawn) = escrow.locks(id);
        return keccak256(abi.encode(owner, shares, created, unlock, end, withdrawn));
    }

    function testUpgradePreservesLocksVotesAndWithdrawals() external {
        vm.prank(alice);
        escrow.vote(aliceLock, 1, 1000 ether, true, 0);
        vm.prank(bob);
        escrow.requestUnlock(bobLock);
        bytes32 aliceBefore = _lockHash(aliceLock);
        bytes32 bobBefore = _lockHash(bobLock);
        (,,, uint256 deadline,,) = escrow.locks(bobLock);

        _escrowAdmin()
            .upgradeAndCall(ITransparentUpgradeableProxy(address(escrow)), address(new StakedRailVotingV2()), "");
        assertEq(StakedRailVotingV2(address(escrow)).version(), 2);
        assertEq(_lockHash(aliceLock), aliceBefore);
        assertEq(_lockHash(bobLock), bobBefore);
        assertEq(address(escrow.stRail()), address(d.strategy));
        assertEq(address(escrow.positionManager()), address(d.manager));
        assertEq(address(escrow.voting()), address(voting));
        assertEq(address(escrow.snapshots()), address(staking));
        assertEq(address(escrow.supplyHook()), address(hook));
        assertEq(escrow.unlockCooldown(), 7 days);
        assertEq(escrow.totalLocked(), 10_000 ether);
        assertEq(d.strategy.balanceOf(address(escrow)), 10_000 ether);
        assertEq(escrow.votesUsed(1, aliceLock), 1000 ether);
        assertEq(escrow.votingPower(bobLock, 1, 0), 0);

        vm.startPrank(alice);
        escrow.vote(aliceLock, 1, 2000 ether, false, 0);
        vm.expectRevert(StakedRailVoting.InsufficientVotingPower.selector);
        escrow.vote(aliceLock, 1, 1, true, 0);
        vm.stopPrank();
        assertEq(voting.getVotes(1, address(d.manager)), 3000 ether);

        vm.warp(deadline);
        vm.startPrank(bob);
        escrow.withdraw(bobLock);
        vm.expectRevert(StakedRailVoting.InvalidLock.selector);
        escrow.withdraw(bobLock);
        vm.stopPrank();
        assertEq(escrow.totalLocked(), 3000 ether);
        assertEq(d.strategy.balanceOf(bob), 7000 ether);
        uint256 fresh = _lock(bob, 7000 ether);
        assertEq(fresh, 2);
        assertEq(escrow.votingPower(fresh, 1, 0), 0);
        assertEq(escrow.totalLocked(), 10_000 ether);
    }

    function testOnlyProxyOwnerCanUpgrade() external {
        ProxyAdmin admin = _escrowAdmin();
        address implementation = address(new StakedRailVotingV2());
        assertEq(admin.owner(), address(this));
        vm.prank(alice);
        vm.expectRevert();
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(escrow)), implementation, "");
    }

    function testImplementationAndProxyCannotReinitialize() external {
        StakedRailVoting implementation = new StakedRailVoting();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(d.strategy, IRailgunVoting(address(voting)), hook, 7 days);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        escrow.initialize(d.strategy, IRailgunVoting(address(voting)), hook, 7 days);
    }

    function testVotingStorageLayout() external view {
        bytes32 slot = bytes32(0);
        assertEq(address(uint160(uint256(vm.load(address(escrow), slot)))), address(d.strategy));
        assertEq(uint256(vm.load(address(escrow), bytes32(uint256(slot) + 6))), 10_000 ether);
        assertEq(uint256(vm.load(address(escrow), bytes32(uint256(slot) + 7))), 2);
    }

    function testVotingKeyManagerRoleCanBeDelegatedAndRevoked() external {
        bytes32 role = d.manager.VOTING_KEY_MANAGER_ROLE();
        assertTrue(d.manager.hasRole(role, address(this)));
        assertEq(d.manager.getRoleAdmin(role), d.manager.DEFAULT_ADMIN_ROLE());

        d.manager.revokeRole(role, address(this));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), role)
        );
        d.manager.setVotingKey(IRailgunVoting(address(voting)), address(0));

        d.manager.grantRole(role, alice);
        assertFalse(d.manager.hasRole(d.manager.DEFAULT_ADMIN_ROLE(), alice));
        vm.startPrank(alice);
        d.manager.setVotingKey(IRailgunVoting(address(voting)), bob);
        assertEq(voting.votingKey(address(d.manager)), bob);
        d.manager.setVotingKey(IRailgunVoting(address(voting)), address(0));
        assertEq(voting.votingKey(address(d.manager)), address(0));
        vm.stopPrank();

        d.manager.revokeRole(role, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        d.manager.setVotingKey(IRailgunVoting(address(voting)), address(escrow));
    }

    function testOnlyLockOwnerCanVoteOrWithdraw() external {
        vm.expectRevert(StakedRailVoting.NotOwner.selector);
        escrow.vote(aliceLock, 1, 1, true, 0);
        vm.expectRevert(StakedRailVoting.NotOwner.selector);
        escrow.withdraw(aliceLock);
        vm.expectRevert(StakedRailVoting.NotOwner.selector);
        escrow.requestUnlock(aliceLock);
    }

    function testRemovingHookDoesNotBlockVotingLocksOrExits() external {
        _deposit(alice, 1);
        d.strategy.setHooks(address(0));
        vm.startPrank(alice);
        escrow.vote(aliceLock, 1, 1, true, 0);
        d.strategy.approve(address(escrow), 1);
        escrow.lock(1);
        escrow.requestUnlock(aliceLock);
        vm.warp(block.timestamp + 7 days);
        escrow.withdraw(aliceLock);
        vm.stopPrank();
        assertEq(d.strategy.balanceOf(alice), 3000 ether);
    }

    function testHistoricalSupplyUsesStateStrictlyBeforeCutoff() external {
        assertEq(hook.totalSupplyBefore(cutoff), 10_000 ether);
        _deposit(alice, 1000 ether);
        hook.checkpoint();
        assertEq(hook.totalSupplyBefore(cutoff), 10_000 ether);
        // A checkpoint at this timestamp is excluded until time advances.
        assertEq(hook.totalSupplyBefore(block.timestamp), 10_000 ether);
        vm.warp(block.timestamp + 1);
        assertEq(hook.totalSupplyBefore(block.timestamp), 11_000 ether);
    }

    function testWithdrawnSharesCannotBeRelockedToReuseOldVotes() external {
        vm.prank(alice);
        escrow.requestUnlock(aliceLock);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        escrow.withdraw(aliceLock);
        uint256 newLock = _lock(alice, 3000 ether);
        assertEq(escrow.votingPower(newLock, 1, 0), 0);
        assertEq(escrow.votingPower(aliceLock, 1, 0), 0);
    }

    function testLateDepositCannotVoteAndDoesNotDiluteHistoricalAllocation() external {
        uint256 shares = _deposit(alice, 10_000 ether);
        uint256 late = _lock(alice, shares);
        assertEq(escrow.votingPower(late, 1, 0), 0);
        assertEq(escrow.votingPower(aliceLock, 1, 0), 3000 ether);
        vm.prank(alice);
        vm.expectRevert(StakedRailVoting.IneligibleLock.selector);
        escrow.vote(late, 1, 1, true, 0);
    }

    function testLockDoesNotExpireWithoutUnlockRequest() external {
        vm.warp(cutoff + 365 days);
        voting.prepare(3, block.timestamp - 3 days, cutoff / 1 days);
        assertEq(escrow.votingPower(aliceLock, 3, 0), 3000 ether);
        vm.startPrank(alice);
        escrow.vote(aliceLock, 3, 1, true, 0);
        vm.expectRevert(StakedRailVoting.StillLocked.selector);
        escrow.withdraw(aliceLock);
        vm.stopPrank();
    }

    function testWithdrawRequiresRequestAndFullCooldownAndNoDoubleWithdrawal() external {
        vm.startPrank(alice);
        vm.expectRevert(StakedRailVoting.StillLocked.selector);
        escrow.withdraw(aliceLock);
        escrow.requestUnlock(aliceLock);
        vm.expectRevert(StakedRailVoting.InvalidLock.selector);
        escrow.requestUnlock(aliceLock);
        vm.warp(block.timestamp + 7 days - 1);
        vm.expectRevert(StakedRailVoting.StillLocked.selector);
        escrow.withdraw(aliceLock);
        vm.warp(block.timestamp + 1);
        escrow.withdraw(aliceLock);
        assertEq(d.strategy.balanceOf(alice), 3000 ether);
        assertEq(escrow.totalLocked(), 7000 ether);
        vm.expectRevert(StakedRailVoting.InvalidLock.selector);
        escrow.withdraw(aliceLock);
        vm.expectRevert(StakedRailVoting.InvalidLock.selector);
        escrow.requestUnlock(aliceLock);
        vm.stopPrank();
        assertEq(escrow.votingPower(aliceLock, 1, 0), 0);
    }

    function testUpstreamFailureRollsBackUsageAndDoesNotBlockWithdrawal() external {
        d.manager.setVotingKey(IRailgunVoting(address(voting)), address(0));
        vm.prank(alice);
        vm.expectRevert(bytes("not voting key"));
        escrow.vote(aliceLock, 1, 1000 ether, true, 0);
        assertEq(escrow.votesUsed(1, aliceLock), 0);
        (,,,, uint256 lastVoteEnd,) = escrow.locks(aliceLock);
        assertEq(lastVoteEnd, 0);
        vm.prank(alice);
        escrow.requestUnlock(aliceLock);
        vm.warp(block.timestamp + 7 days);
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
        hook = StakedRailSupplyHook(
            address(
                new TransparentUpgradeableProxy(
                    address(new StakedRailSupplyHook()),
                    address(this),
                    abi.encodeCall(StakedRailSupplyHook.initialize, (IVault(address(d.strategy))))
                )
            )
        );
        d.strategy.grantRole(d.strategy.HOOKS_MANAGER_ROLE(), address(this));
        d.strategy.setHooks(address(new MockHookRouter(IVault(address(d.strategy)), hook)));
        hook.checkpoint();
        voting = new MockRailgunVoting(address(staking));
        escrow = StakedRailVoting(
            address(
                new TransparentUpgradeableProxy(
                    address(new StakedRailVoting()),
                    address(this),
                    abi.encodeCall(
                        StakedRailVoting.initialize, (d.strategy, IRailgunVoting(address(voting)), hook, 7 days)
                    )
                )
            )
        );
        d.manager.setVotingKey(IRailgunVoting(address(voting)), address(escrow));
        _deposit(alice, 1000 ether);
        rail.mint(address(d.strategy), 1000 ether);
        uint256 bobShares = _deposit(bob, 1000 ether);
        assertEq(bobShares, 500 ether);
        d.processor.rebalanceStaking(3);
        uint256 a = _lock(alice, 1000 ether);
        uint256 b = _lock(bob, bobShares);
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
        escrow.lock(0);
        StakedRailVoting implementation = new StakedRailVoting();
        vm.expectRevert(StakedRailVoting.InvalidConfiguration.selector);
        StakedRailVoting(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    address(this),
                    abi.encodeCall(StakedRailVoting.initialize, (d.strategy, IRailgunVoting(address(voting)), hook, 0))
                )
            )
        );
        MockRailgunVoting wrong = new MockRailgunVoting(address(0xBEEF));
        vm.expectRevert();
        d.manager.setVotingKey(IRailgunVoting(address(wrong)), address(escrow));
        vm.prank(alice);
        vm.expectRevert();
        d.manager.setVotingKey(IRailgunVoting(address(voting)), alice);
    }

    function testUnlockRequestImmediatelyDisablesFurtherVotesButPreservesCastVotes() external {
        vm.startPrank(alice);
        escrow.vote(aliceLock, 1, 1000 ether, true, 0);
        escrow.requestUnlock(aliceLock);
        assertEq(escrow.votingPower(aliceLock, 1, 0), 0);
        assertEq(escrow.votingPower(aliceLock, 2, 0), 0);
        assertEq(escrow.votesUsed(1, aliceLock), 1000 ether);
        assertEq(voting.getVotes(1, address(d.manager)), 1000 ether);
        vm.expectRevert(StakedRailVoting.IneligibleLock.selector);
        escrow.vote(aliceLock, 1, 1, false, 0);
        vm.expectRevert(StakedRailVoting.IneligibleLock.selector);
        escrow.vote(aliceLock, 2, 1, true, 0);
        vm.stopPrank();
        // Another holder's lock remains eligible; the requesting holder's votes are not redistributed.
        assertEq(escrow.votingPower(bobLock, 2, 0), 7000 ether);
        vm.warp(block.timestamp + 8 days);
        voting.prepare(3, block.timestamp - 3 days, cutoff / 1 days);
        assertEq(escrow.votingPower(aliceLock, 3, 0), 0);
        vm.prank(alice);
        vm.expectRevert(StakedRailVoting.IneligibleLock.selector);
        escrow.vote(aliceLock, 3, 1, true, 0);
    }

    function testVotingAtLastMomentStillRequiresFullCooldownAfterRequest() external {
        uint256 finalDeadline = cutoff + 1 hours + voting.VOTING_NAY_END_OFFSET();
        vm.warp(finalDeadline - 1);
        vm.startPrank(alice);
        escrow.vote(aliceLock, 1, 1, false, 0);
        escrow.requestUnlock(aliceLock);
        (,,, uint256 unlockAt, uint256 lastVoteEnd,) = escrow.locks(aliceLock);
        assertEq(unlockAt, finalDeadline - 1 + 7 days);
        assertEq(lastVoteEnd, finalDeadline);
        vm.warp(finalDeadline);
        vm.expectRevert(StakedRailVoting.StillLocked.selector);
        escrow.withdraw(aliceLock);
        vm.warp(unlockAt);
        escrow.withdraw(aliceLock);
        vm.stopPrank();
    }

    function testFuzzUnlockWaitsForBothCooldownAndLatestVotedDeadline(uint256 cooldown) external {
        cooldown = bound(cooldown, 1, 30 days);
        escrow = StakedRailVoting(
            address(
                new TransparentUpgradeableProxy(
                    address(new StakedRailVoting()),
                    address(this),
                    abi.encodeCall(
                        StakedRailVoting.initialize, (d.strategy, IRailgunVoting(address(voting)), hook, cooldown)
                    )
                )
            )
        );
        d.manager.setVotingKey(IRailgunVoting(address(voting)), address(escrow));
        _deposit(alice, 100 ether);
        uint256 id = _lock(alice, 100 ether);
        // Use the next interval boundary, strictly after this new lock.
        cutoff = (block.timestamp / 1 days + 1) * 1 days;
        _snapshot(10_000 ether);
        voting.prepare(3, cutoff + 1 hours, cutoff / 1 days);
        voting.prepare(4, cutoff + 2 hours, cutoff / 1 days);
        vm.warp(cutoff + 3 days);
        vm.startPrank(alice);
        // Voting on an earlier-ending proposal last must not shorten the deadline.
        escrow.vote(id, 4, 1, true, 0);
        escrow.vote(id, 3, 1, false, 0);
        uint256 deadline = cutoff + 2 hours + voting.VOTING_NAY_END_OFFSET();
        uint256 expectedUnlock = block.timestamp + cooldown;
        if (deadline > expectedUnlock) expectedUnlock = deadline;
        escrow.requestUnlock(id);
        (,,, uint256 unlockAt, uint256 lastVoteEnd,) = escrow.locks(id);
        assertEq(lastVoteEnd, deadline);
        assertEq(unlockAt, expectedUnlock);
        assertEq(escrow.totalLocked(), 100 ether);
        vm.warp(unlockAt - 1);
        vm.expectRevert(StakedRailVoting.StillLocked.selector);
        escrow.withdraw(id);
        vm.warp(unlockAt);
        escrow.withdraw(id);
        vm.stopPrank();
        assertEq(d.strategy.balanceOf(alice), 100 ether);
        assertEq(escrow.totalLocked(), 0);
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

contract StakedRailVotingV2 is StakedRailVoting {
    function version() external pure returns (uint256) {
        return 2;
    }
}
