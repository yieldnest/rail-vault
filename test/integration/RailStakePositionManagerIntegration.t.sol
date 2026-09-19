// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRailgunStaking} from "../../src/railgun/IRailgunStaking.sol";
import {RailStakePositionManager} from "../../src/railgun/RailStakePositionManager.sol";
import {IRailgunGovernorRewards} from "../../src/railgun/IRailgunGovernorRewards.sol";

interface IMainnetGovernorRewards is IRailgunGovernorRewards {
    function currentInterval() external view returns (uint256);
    function nextSnapshotPreCalcInterval() external view returns (uint256);
    function DISTRIBUTION_INTERVAL() external view returns (uint256);
    function STAKING_DEPLOY_TIME() external view returns (uint256);
    function prefetchGlobalSnapshots(uint256 endingInterval, uint256[] calldata hints, IERC20[] calldata tokens)
        external;
}

contract RailStakePositionManagerIntegrationTest is Test {
    address internal constant RAILGUN_STAKING = 0xEE6A649Aa3766bD117e12C161726b693A1B2Ee20;

    address internal strategy = makeAddr("strategy");
    address internal keeper = makeAddr("keeper");
    address internal receiver = makeAddr("receiver");

    IERC20 internal rail;
    IRailgunStaking internal staking;
    RailStakePositionManager internal manager;
    uint256 internal funded;
    uint256 internal initialGlobalStaked;
    uint256[] internal expectedAmounts;
    uint256[] internal expectedStakeTimes;
    address[] internal expectedDelegates;

    function setUp() external {
        staking = IRailgunStaking(RAILGUN_STAKING);
        rail = IERC20(staking.stakingToken());
        manager = new RailStakePositionManager(address(this), rail, staking);
        manager.grantRole(manager.CREATOR_ROLE(), strategy);
        manager.grantRole(manager.QUEUER_ROLE(), keeper);
        manager.grantRole(manager.CLAIMER_ROLE(), keeper);
        initialGlobalStaked = _globalStaked();
    }

    function testCreatePosition() external {
        assertEq(address(staking), RAILGUN_STAKING);
        assertEq(staking.stakingToken(), address(rail));

        uint256 amount = 1000 ether;
        uint256 stakeId = _create(amount);

        assertEq(manager.activePrincipal(), amount);
        assertEq(manager.queuedPrincipal(), 0);
        assertEq(manager.activePositionCount(), 1);

        (, uint256 principal,, uint256 locktime, uint256 claimedTime) = staking.stakes(address(manager), stakeId);
        assertEq(principal, amount);
        assertEq(locktime, 0);
        assertEq(claimedTime, 0);
        _assertAccounting();
    }

    function testClaimPositionRevertsForActiveStake() external {
        uint256 stakeId = _create(1000 ether);
        vm.expectRevert(RailStakePositionManager.InvalidPositionStatus.selector);
        vm.prank(keeper);
        manager.claimPosition(stakeId, receiver);
        _assertAccounting();
    }

    function testQueuePosition() external {
        uint256 amount = 1000 ether;
        uint256 stakeId = _create(amount);
        vm.prank(keeper);
        uint256 queued = manager.queuePosition(stakeId);

        assertEq(queued, amount);
        assertEq(manager.activePrincipal(), 0);
        assertEq(manager.queuedPrincipal(), amount);
        assertEq(manager.activePositionCount(), 0);

        (,,, uint256 locktime, uint256 claimedTime) = staking.stakes(address(manager), stakeId);
        assertEq(locktime, block.timestamp + staking.STAKE_LOCKTIME());
        assertEq(claimedTime, 0);
        _assertAccounting();
    }

    function testQueuePositionRevertsForQueuedStake() external {
        uint256 stakeId = _create(1000 ether);
        _queue(stakeId);
        vm.expectRevert(RailStakePositionManager.InvalidPositionStatus.selector);
        vm.prank(keeper);
        manager.queuePosition(stakeId);
        _assertAccounting();
    }

    function testClaimPositionRevertsAtLocktime() external {
        uint256 stakeId = _create(1000 ether);
        _queue(stakeId);
        (,,, uint256 locktime,) = staking.stakes(address(manager), stakeId);
        vm.warp(locktime);
        vm.expectRevert(RailStakePositionManager.PositionNotMatured.selector);
        vm.prank(keeper);
        manager.claimPosition(stakeId, receiver);
        _assertAccounting();
    }

    function testClaimPosition() external {
        uint256 amount = 1000 ether;
        uint256 stakeId = _create(amount);
        _queue(stakeId);
        (,,, uint256 locktime,) = staking.stakes(address(manager), stakeId);
        vm.warp(locktime + 1);

        vm.prank(keeper);
        uint256 claimed = manager.claimPosition(stakeId, receiver);

        assertEq(claimed, amount);
        assertEq(manager.activePrincipal(), 0);
        assertEq(manager.queuedPrincipal(), 0);
        assertEq(manager.activePositionCount(), 0);
        assertEq(rail.balanceOf(receiver), amount);

        (,,,, uint256 claimedTime) = staking.stakes(address(manager), stakeId);
        assertEq(claimedTime, block.timestamp);
        _assertAccounting();
    }

    function testClaimPositionRevertsForClaimedStake() external {
        uint256 stakeId = _create(1000 ether);
        _queue(stakeId);
        vm.warp(block.timestamp + staking.STAKE_LOCKTIME() + 1);
        _claim(stakeId);
        vm.expectRevert(RailStakePositionManager.InvalidPositionStatus.selector);
        vm.prank(keeper);
        manager.claimPosition(stakeId, receiver);
        _assertAccounting();
    }

    function testQueuePositionRevertsForClaimedStake() external {
        uint256 stakeId = _create(1000 ether);
        _queue(stakeId);
        vm.warp(block.timestamp + staking.STAKE_LOCKTIME() + 1);
        _claim(stakeId);
        vm.expectRevert(RailStakePositionManager.InvalidPositionStatus.selector);
        vm.prank(keeper);
        manager.queuePosition(stakeId);
        _assertAccounting();
    }

    function testQueuePositionRevertsForUnknownStake() external {
        vm.expectRevert();
        vm.prank(keeper);
        manager.queuePosition(0);
        _assertAccounting();
    }

    function testClaimPositionRevertsForUnknownStake() external {
        vm.expectRevert();
        vm.prank(keeper);
        manager.claimPosition(0, receiver);
        _assertAccounting();
    }

    function testDeployment() external view {
        assertEq(address(manager.rail()), address(rail));
        assertEq(address(manager.staking()), RAILGUN_STAKING);
        assertTrue(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(manager.hasRole(manager.CREATOR_ROLE(), address(this)));
        assertFalse(manager.paused());
        assertEq(manager.activeStakeIdsList().length, 0);
    }

    function testMixedPositionsAndOutOfOrderClaims() external {
        _create(1000 ether);
        _create(2300 ether);
        _create(400 ether);
        _queue(1);
        vm.warp(block.timestamp + 5 days);
        _queue(0);
        _assertAccounting();

        (,,, uint256 unlockAt,) = staking.stakes(address(manager), 0);
        vm.warp(unlockAt + 1);
        _claim(0);
        _assertAccounting();
        _claim(1);
        _assertAccounting();
        assertEq(manager.activeStakeIdsList()[0], 2);
        assertEq(manager.activePrincipal(), 400 ether);
        assertEq(rail.balanceOf(receiver), 3300 ether);
    }

    function testClaimMaturedPositions() external {
        _create(1000 ether);
        _create(2000 ether);
        _queue(0);
        _queue(1);
        vm.warp(block.timestamp + staking.STAKE_LOCKTIME() + 1);
        uint256[] memory ids = _pair(1, 0);
        vm.prank(keeper);
        assertEq(manager.claimMaturedPositions(ids, receiver), 3000 ether);
        _assertAccounting();
    }

    function testClaimMaturedPositionsEmptyBatch() external {
        vm.prank(keeper);
        assertEq(manager.claimMaturedPositions(new uint256[](0), receiver), 0);
        _assertAccounting();
    }

    function testBatchWithImmaturePositionRollsBackEarlierClaim() external {
        _create(1000 ether);
        _create(2000 ether);
        _queue(0);
        vm.warp(block.timestamp + 1 days);
        _queue(1);
        (,,, uint256 unlockAt,) = staking.stakes(address(manager), 0);
        vm.warp(unlockAt + 1);
        uint256[] memory ids = _pair(0, 1);
        vm.expectRevert(RailStakePositionManager.PositionNotMatured.selector);
        vm.prank(keeper);
        manager.claimMaturedPositions(ids, receiver);
        (,,,, uint256 claimedTime) = staking.stakes(address(manager), 0);
        assertEq(claimedTime, 0);
        assertEq(rail.balanceOf(receiver), 0);
        _assertAccounting();
    }

    function testDuplicateBatchRollsBackEntireClaim() external {
        _create(1000 ether);
        _queue(0);
        vm.warp(block.timestamp + staking.STAKE_LOCKTIME() + 1);
        uint256[] memory ids = _pair(0, 0);
        vm.expectRevert(RailStakePositionManager.InvalidPositionStatus.selector);
        vm.prank(keeper);
        manager.claimMaturedPositions(ids, receiver);
        (,,,, uint256 claimedTime) = staking.stakes(address(manager), 0);
        assertEq(claimedTime, 0);
        assertEq(rail.balanceOf(receiver), 0);
        _assertAccounting();
    }

    function testZeroReceiverRollsBackExternalClaim() external {
        _create(1000 ether);
        _queue(0);
        vm.warp(block.timestamp + staking.STAKE_LOCKTIME() + 1);
        vm.expectRevert();
        vm.prank(keeper);
        manager.claimPosition(0, address(0));
        (,,,, uint256 claimedTime) = staking.stakes(address(manager), 0);
        assertEq(claimedTime, 0);
        _assertAccounting();
    }

    function testCreatePositionRevertsForZeroAmount() external {
        vm.expectRevert();
        vm.prank(strategy);
        manager.createPosition(0);
        assertEq(rail.allowance(address(manager), address(staking)), 0);
        _assertAccounting();
    }

    function testCreatePositionRevertsForInsufficientBalance() external {
        vm.expectRevert();
        vm.prank(strategy);
        manager.createPosition(1000 ether);
        assertEq(staking.stakesLength(address(manager)), 0);
        assertEq(rail.allowance(address(manager), address(staking)), 0);
        _assertAccounting();
    }

    function testCreatePositionRevertsWhilePaused() external {
        manager.pause();
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(strategy);
        manager.createPosition(1 ether);
        assertTrue(manager.paused());
        _assertAccounting();
    }

    function testQueuePositionRevertsWhilePaused() external {
        _create(1000 ether);
        manager.pause();
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(keeper);
        manager.queuePosition(0);
        _assertAccounting();
    }

    function testClaimPositionWhilePaused() external {
        _create(1000 ether);
        _queue(0);
        manager.pause();
        vm.warp(block.timestamp + staking.STAKE_LOCKTIME() + 1);
        _claim(0);
        _assertAccounting();
        assertTrue(manager.paused());
    }

    function testRoleIsolationAndRevocation() external {
        address queuer = makeAddr("queuer");
        address claimer = makeAddr("claimer");
        address outsider = makeAddr("outsider");
        manager.revokeRole(manager.QUEUER_ROLE(), keeper);
        manager.revokeRole(manager.CLAIMER_ROLE(), keeper);
        manager.grantRole(manager.QUEUER_ROLE(), queuer);
        manager.grantRole(manager.CLAIMER_ROLE(), claimer);
        _create(1000 ether);

        _expectRole(outsider, manager.CREATOR_ROLE());
        manager.createPosition(1 ether);
        _expectRole(claimer, manager.QUEUER_ROLE());
        manager.queuePosition(0);
        _expectRole(keeper, manager.QUEUER_ROLE());
        manager.queuePosition(0);
        _expectRole(queuer, manager.CLAIMER_ROLE());
        manager.claimPosition(0, receiver);
        _expectRole(queuer, manager.CLAIMER_ROLE());
        manager.claimMaturedPositions(new uint256[](0), receiver);
        _expectRole(outsider, manager.DEFAULT_ADMIN_ROLE());
        manager.pause();
        _expectRole(outsider, manager.DEFAULT_ADMIN_ROLE());
        manager.unpause();
        bytes32 creatorRole = manager.CREATOR_ROLE();
        _expectRole(outsider, manager.DEFAULT_ADMIN_ROLE());
        manager.grantRole(creatorRole, outsider);

        vm.prank(queuer);
        manager.queuePosition(0);
        vm.warp(block.timestamp + staking.STAKE_LOCKTIME() + 1);
        _expectRole(keeper, manager.CLAIMER_ROLE());
        manager.claimPosition(0, receiver);
        vm.prank(claimer);
        manager.claimPosition(0, receiver);
        manager.revokeRole(creatorRole, strategy);
        _expectRole(strategy, creatorRole);
        manager.createPosition(1 ether);
        _assertAccounting();
    }

    function testClaimRewardsRequiresKeeperRole() external {
        IERC20[] memory tokens = new IERC20[](0);
        uint256[] memory hints = new uint256[](0);
        _expectRole(strategy, manager.KEEPER_ROLE());
        manager.claimRewards(IRailgunGovernorRewards(address(0)), tokens, 0, 0, hints, receiver);
        _assertAccounting();
    }

    function testClaimRewardsRevertsForZeroRewardsAddress() external {
        IERC20[] memory tokens = new IERC20[](0);
        uint256[] memory hints = new uint256[](0);
        manager.grantRole(manager.KEEPER_ROLE(), keeper);
        vm.expectRevert(RailStakePositionManager.ZeroAddress.selector);
        vm.prank(keeper);
        manager.claimRewards(IRailgunGovernorRewards(address(0)), tokens, 0, 0, hints, receiver);
        _assertAccounting();
    }

    function testClaimRewardsRevertsForZeroReceiver() external {
        IERC20[] memory tokens = new IERC20[](0);
        uint256[] memory hints = new uint256[](0);
        manager.grantRole(manager.KEEPER_ROLE(), keeper);
        vm.expectRevert(RailStakePositionManager.ZeroAddress.selector);
        vm.prank(keeper);
        manager.claimRewards(IRailgunGovernorRewards(RAILGUN_STAKING), tokens, 0, 0, hints, address(0));
        _assertAccounting();
    }

    function testHarvestRealRewardsAndDoNotForwardExistingBalances() external {
        IMainnetGovernorRewards rewards = IMainnetGovernorRewards(0xA02782CE1bF85f56f8cC7C0E66e61299Ac75c86f);
        IERC20 weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        assertTrue(rewards.tokens(weth));
        manager.grantRole(manager.KEEPER_ROLE(), keeper);
        _create(1000 ether);

        uint256 interval = rewards.currentInterval() + 1;
        vm.warp(rewards.STAKING_DEPLOY_TIME() + (interval + 1) * rewards.DISTRIBUTION_INTERVAL());
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = weth;
        uint256[] memory globalHints = new uint256[](interval - rewards.nextSnapshotPreCalcInterval() + 1);
        rewards.prefetchGlobalSnapshots(interval, globalHints, tokens);

        uint256[] memory hints = new uint256[](1);
        uint256 expected = rewards.calculateRewards(tokens, address(manager), interval, interval, hints, true)[0];
        assertGt(expected, 0);
        deal(address(weth), address(manager), 1 ether);
        uint256 balanceBefore = weth.balanceOf(receiver);
        vm.prank(keeper);
        uint256[] memory claimed = manager.claimRewards(rewards, tokens, interval, interval, hints, receiver);
        assertEq(claimed[0], expected);
        assertEq(weth.balanceOf(receiver) - balanceBefore, expected);
        assertEq(weth.balanceOf(address(manager)), 1 ether);

        vm.prank(keeper);
        claimed = manager.claimRewards(rewards, tokens, interval, interval, hints, receiver);
        assertEq(claimed[0], 0);
        assertEq(weth.balanceOf(receiver) - balanceBefore, expected);
        assertEq(weth.balanceOf(address(manager)), 1 ether);
        _assertAccounting();
    }

    function testPredicatesAtLocktimeBoundary() external {
        _create(1000 ether);
        assertTrue(manager.isActivePosition(0, 0));
        assertFalse(manager.isQueuedPosition(0, 0));
        assertFalse(manager.isClaimablePosition(0, 0));
        _queue(0);
        (,,, uint256 unlockAt,) = staking.stakes(address(manager), 0);
        assertFalse(manager.isActivePosition(unlockAt, 0));
        assertTrue(manager.isQueuedPosition(unlockAt, 0));
        vm.warp(unlockAt);
        assertFalse(manager.isClaimablePosition(unlockAt, 0));
        vm.warp(unlockAt + 1);
        assertTrue(manager.isClaimablePosition(unlockAt, 0));
        _claim(0);
        assertFalse(manager.isActivePosition(unlockAt, block.timestamp));
        assertFalse(manager.isQueuedPosition(unlockAt, block.timestamp));
        assertFalse(manager.isClaimablePosition(unlockAt, block.timestamp));
        _assertAccounting();
    }

    function testFuzzMixedLifecycleConservesPrincipal(uint256 seed, uint8 countSeed) external {
        uint256 count = bound(uint256(countSeed), 1, 12);
        for (uint256 i = 0; i < count; i++) {
            _create(bound(uint256(keccak256(abi.encode(seed, i))), 1, 100_000 ether));
            _assertAccounting();
        }
        for (uint256 i = 0; i < count; i++) {
            uint256[] memory active = manager.activeStakeIdsList();
            uint256 index = uint256(keccak256(abi.encode(seed, i, "queue"))) % active.length;
            _queue(active[index]);
            vm.warp(block.timestamp + 1 hours);
            _assertAccounting();
        }
        vm.warp(block.timestamp + staking.STAKE_LOCKTIME() + 1);
        uint256 offset = seed % count;
        for (uint256 i = 0; i < count; i++) {
            _claim((i + offset) % count);
            _assertAccounting();
        }
        assertEq(rail.balanceOf(receiver), funded);
    }

    function testRepeatedInterleavedStakesQueuesAndClaims() external {
        // Each round leaves active and queued stakes behind for the following round.
        for (uint256 round = 0; round < 5; round++) {
            for (uint256 i = 0; i < 6; i++) {
                _create((round + 1) * (i + 1) * 1000 ether);
                _assertAccounting();
            }
            for (uint256 i = 0; i < 4; i++) {
                uint256[] memory active = manager.activeStakeIdsList();
                _queue(active[(round + i) % active.length]);
                _assertAccounting();
            }
            // Newer queued stakes must survive claims of older, mature stakes.
            uint256 count = staking.stakesLength(address(manager));
            for (uint256 i = count; i > 0; i--) {
                (,,, uint256 locktime, uint256 claimedTime) = staking.stakes(address(manager), i - 1);
                if (locktime != 0 && claimedTime == 0 && block.timestamp > locktime) {
                    _claim(i - 1);
                    _assertAccounting();
                }
            }
            assertGt(manager.activePrincipal(), 0);
            assertGt(manager.queuedPrincipal(), 0);
            vm.warp(block.timestamp + staking.STAKE_LOCKTIME() + 1);
        }
        while (manager.activePositionCount() != 0) {
            uint256[] memory active = manager.activeStakeIdsList();
            _queue(active[active.length / 2]);
            _assertAccounting();
        }
        vm.warp(block.timestamp + staking.STAKE_LOCKTIME() + 1);
        for (uint256 i = 0; i < staking.stakesLength(address(manager)); i++) {
            (,,,, uint256 claimedTime) = staking.stakes(address(manager), i);
            if (claimedTime == 0) {
                _claim(i);
                _assertAccounting();
            }
        }
        assertEq(manager.activePositionCount(), 0);
        assertEq(manager.activePrincipal(), 0);
        assertEq(manager.queuedPrincipal(), 0);
        assertEq(rail.balanceOf(receiver), funded);
    }

    function testPause() external {
        manager.pause();
        assertTrue(manager.paused());
        _assertAccounting();
    }

    function testUnpause() external {
        manager.pause();
        manager.unpause();
        assertFalse(manager.paused());
        _create(1000 ether);
        _assertAccounting();
    }

    function testPauseRequiresAdminRole() external {
        _expectRole(keeper, manager.DEFAULT_ADMIN_ROLE());
        manager.pause();
        assertFalse(manager.paused());
        _assertAccounting();
    }

    function testUnpauseRequiresAdminRole() external {
        manager.pause();
        _expectRole(keeper, manager.DEFAULT_ADMIN_ROLE());
        manager.unpause();
        assertTrue(manager.paused());
        _assertAccounting();
    }

    function testActivePositionCount() external {
        assertEq(manager.activePositionCount(), 0);
        _create(1000 ether);
        _create(2000 ether);
        assertEq(manager.activePositionCount(), 2);
        _queue(0);
        assertEq(manager.activePositionCount(), 1);
        _assertAccounting();
    }

    function testActiveStakeIdsList() external {
        for (uint256 i = 0; i < 4; i++) {
            _create((i + 1) * 1000 ether);
            _assertAccounting();
        }
        _queue(1);
        uint256[] memory expected = new uint256[](3);
        expected[0] = 0;
        expected[1] = 3;
        expected[2] = 2;
        assertEq(manager.activeStakeIdsList(), expected);
        _assertAccounting();
        _queue(2);
        assertEq(manager.activeStakeIdsList(), _pair(0, 3));
        _assertAccounting();
        _queue(0);
        assertEq(manager.activeStakeIdsList()[0], 3);
        _assertAccounting();
        _queue(3);
        assertEq(manager.activeStakeIdsList().length, 0);
        _assertAccounting();
    }

    function testIsActivePosition() external view {
        assertTrue(manager.isActivePosition(0, 0));
        assertFalse(manager.isActivePosition(1, 0));
        assertFalse(manager.isActivePosition(0, 1));
        assertFalse(manager.isActivePosition(1, 1));
    }

    function testIsQueuedPosition() external view {
        assertFalse(manager.isQueuedPosition(0, 0));
        assertTrue(manager.isQueuedPosition(1, 0));
        assertFalse(manager.isQueuedPosition(0, 1));
        assertFalse(manager.isQueuedPosition(1, 1));
    }

    function testIsClaimablePosition() external {
        uint256 locktime = block.timestamp + 30 days;
        assertFalse(manager.isClaimablePosition(locktime, 0));
        vm.warp(locktime);
        assertFalse(manager.isClaimablePosition(locktime, 0));
        vm.warp(locktime + 1);
        assertTrue(manager.isClaimablePosition(locktime, 0));
        assertFalse(manager.isClaimablePosition(locktime, block.timestamp));
        assertFalse(manager.isClaimablePosition(0, 0));
    }

    function testCreatePositionRequiresCreatorRole() external {
        _expectRole(keeper, manager.CREATOR_ROLE());
        manager.createPosition(1000 ether);
        _assertAccounting();
    }

    function testQueuePositionRequiresQueuerRole() external {
        uint256 id = _create(1000 ether);
        _expectRole(strategy, manager.QUEUER_ROLE());
        manager.queuePosition(id);
        _assertAccounting();
    }

    function testClaimPositionRequiresClaimerRole() external {
        uint256 id = _create(1000 ether);
        _queue(id);
        vm.warp(block.timestamp + staking.STAKE_LOCKTIME() + 1);
        _expectRole(strategy, manager.CLAIMER_ROLE());
        manager.claimPosition(id, receiver);
        _assertAccounting();
    }

    function testClaimMaturedPositionsRequiresClaimerRole() external {
        uint256 id = _create(1000 ether);
        _queue(id);
        vm.warp(block.timestamp + staking.STAKE_LOCKTIME() + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        _expectRole(strategy, manager.CLAIMER_ROLE());
        manager.claimMaturedPositions(ids, receiver);
        _assertAccounting();
    }

    function _create(uint256 amount) internal returns (uint256 id) {
        uint256[] memory beforeIds = manager.activeStakeIdsList();
        deal(address(rail), address(manager), rail.balanceOf(address(manager)) + amount);
        funded += amount;
        vm.prank(strategy);
        id = manager.createPosition(amount);
        assertEq(id, expectedAmounts.length);
        expectedAmounts.push(amount);
        expectedStakeTimes.push(block.timestamp);
        (address delegate,,,,) = staking.stakes(address(manager), id);
        expectedDelegates.push(delegate);
        uint256[] memory afterIds = manager.activeStakeIdsList();
        assertEq(afterIds.length, beforeIds.length + 1);
        for (uint256 i = 0; i < beforeIds.length; i++) {
            assertEq(afterIds[i], beforeIds[i]);
        }
        assertEq(afterIds[beforeIds.length], id);
    }

    function _queue(uint256 id) internal {
        uint256[] memory beforeIds = manager.activeStakeIdsList();
        vm.prank(keeper);
        assertEq(manager.queuePosition(id), expectedAmounts[id]);
        uint256[] memory afterIds = manager.activeStakeIdsList();
        assertEq(afterIds.length, beforeIds.length - 1);
        for (uint256 i = 0; i < afterIds.length; i++) {
            assertEq(afterIds[i], beforeIds[i] == id ? beforeIds[beforeIds.length - 1] : beforeIds[i]);
        }
        (,,, uint256 locktime, uint256 claimedTime) = staking.stakes(address(manager), id);
        assertEq(locktime, block.timestamp + staking.STAKE_LOCKTIME());
        assertEq(claimedTime, 0);
    }

    function _claim(uint256 id) internal {
        uint256[] memory beforeIds = manager.activeStakeIdsList();
        (,,, uint256 locktime,) = staking.stakes(address(manager), id);
        vm.prank(keeper);
        assertEq(manager.claimPosition(id, receiver), expectedAmounts[id]);
        assertEq(manager.activeStakeIdsList(), beforeIds);
        (,,, uint256 afterLocktime, uint256 claimedTime) = staking.stakes(address(manager), id);
        assertEq(afterLocktime, locktime);
        assertEq(claimedTime, block.timestamp);
    }

    function _pair(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _expectRole(address caller, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", caller, role));
        vm.prank(caller);
    }

    function _globalStaked() internal view returns (uint256) {
        (bool success, bytes memory data) = address(staking).staticcall(abi.encodeWithSignature("totalStaked()"));
        assertTrue(success);
        return abi.decode(data, (uint256));
    }

    // Reconcile local aggregates and membership against every real staking record.
    function _assertAccounting() internal view {
        assertEq(address(manager.rail()), address(rail));
        assertEq(address(manager.staking()), address(staking));
        uint256 active;
        uint256 queued;
        uint256 claimed;
        uint256 count = staking.stakesLength(address(manager));
        assertEq(count, expectedAmounts.length);
        uint256[] memory ids = manager.activeStakeIdsList();
        bool[] memory seen = new bool[](count);
        assertEq(ids.length, manager.activePositionCount());
        for (uint256 i = 0; i < ids.length; i++) {
            assertLt(ids[i], count);
            assertFalse(seen[ids[i]], "duplicate active ID");
            seen[ids[i]] = true;
        }
        for (uint256 i = 0; i < count; i++) {
            (address delegate, uint256 amount, uint256 staketime, uint256 locktime, uint256 claimedTime) =
                staking.stakes(address(manager), i);
            assertEq(amount, expectedAmounts[i], "stake principal changed");
            assertEq(staketime, expectedStakeTimes[i], "stake timestamp changed");
            assertEq(delegate, expectedDelegates[i], "stake delegate changed");
            if (claimedTime != 0) {
                claimed += amount;
                assertFalse(seen[i]);
            } else if (locktime != 0) {
                queued += amount;
                assertFalse(seen[i]);
            } else {
                active += amount;
                assertTrue(seen[i], "missing active ID");
            }
        }
        assertEq(manager.activePrincipal(), active);
        assertEq(manager.queuedPrincipal(), queued);
        assertEq(rail.balanceOf(receiver), claimed);
        assertEq(active + queued + claimed + rail.balanceOf(address(manager)), funded);
        assertEq(_globalStaked(), initialGlobalStaked + active + queued);
    }
}
