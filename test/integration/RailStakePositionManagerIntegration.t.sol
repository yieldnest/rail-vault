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

    function setUp() external {
        staking = IRailgunStaking(RAILGUN_STAKING);
        rail = IERC20(staking.stakingToken());
        manager = new RailStakePositionManager(address(this), rail, staking);
        manager.grantRole(manager.CREATOR_ROLE(), strategy);
        manager.grantRole(manager.QUEUER_ROLE(), keeper);
        manager.grantRole(manager.CLAIMER_ROLE(), keeper);
        initialGlobalStaked = _globalStaked();
    }

    function testCreateQueueAndClaimRealRailgunStake() external {
        assertEq(address(staking), RAILGUN_STAKING);
        assertEq(staking.stakingToken(), address(rail));

        uint256 amount = 1000 ether;
        deal(address(rail), address(manager), amount);

        vm.prank(strategy);
        uint256 stakeId = manager.createPosition(amount);

        assertEq(manager.activePrincipal(), amount);
        assertEq(manager.queuedPrincipal(), 0);
        assertEq(manager.activePositionCount(), 1);

        (, uint256 principal,, uint256 locktime, uint256 claimedTime) = staking.stakes(address(manager), stakeId);
        assertEq(principal, amount);
        assertEq(locktime, 0);
        assertEq(claimedTime, 0);

        vm.expectRevert(RailStakePositionManager.InvalidPositionStatus.selector);
        vm.prank(keeper);
        manager.claimPosition(stakeId, receiver);

        vm.prank(keeper);
        uint256 queued = manager.queuePosition(stakeId);

        assertEq(queued, amount);
        assertEq(manager.activePrincipal(), 0);
        assertEq(manager.queuedPrincipal(), amount);
        assertEq(manager.activePositionCount(), 0);

        (,,, locktime, claimedTime) = staking.stakes(address(manager), stakeId);
        assertGt(locktime, block.timestamp);
        assertEq(claimedTime, 0);

        vm.expectRevert(RailStakePositionManager.InvalidPositionStatus.selector);
        vm.prank(keeper);
        manager.queuePosition(stakeId);

        vm.warp(locktime);
        vm.expectRevert(RailStakePositionManager.PositionNotMatured.selector);
        vm.prank(keeper);
        manager.claimPosition(stakeId, receiver);
        assertEq(manager.queuedPrincipal(), amount);

        vm.warp(locktime + 1);

        vm.prank(keeper);
        uint256 claimed = manager.claimPosition(stakeId, receiver);

        assertEq(claimed, amount);
        assertEq(manager.activePrincipal(), 0);
        assertEq(manager.queuedPrincipal(), 0);
        assertEq(manager.activePositionCount(), 0);
        assertEq(rail.balanceOf(receiver), amount);

        (,,,, claimedTime) = staking.stakes(address(manager), stakeId);
        assertEq(claimedTime, block.timestamp);

        vm.expectRevert(RailStakePositionManager.InvalidPositionStatus.selector);
        vm.prank(keeper);
        manager.claimPosition(stakeId, receiver);

        vm.expectRevert(RailStakePositionManager.InvalidPositionStatus.selector);
        vm.prank(keeper);
        manager.queuePosition(stakeId);
        assertEq(manager.activePrincipal(), 0);
        assertEq(manager.queuedPrincipal(), 0);
        assertEq(rail.balanceOf(receiver), amount);
    }

    function testUnknownStakeIsRejected() external {
        vm.expectRevert();
        vm.prank(keeper);
        manager.queuePosition(0);

        vm.expectRevert();
        vm.prank(keeper);
        manager.claimPosition(0, receiver);
        assertEq(manager.activePrincipal(), 0);
        assertEq(manager.queuedPrincipal(), 0);
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

    function testBatchClaimAndEmptyBatch() external {
        _create(1000 ether);
        _create(2000 ether);
        _queue(0);
        _queue(1);
        vm.warp(block.timestamp + staking.STAKE_LOCKTIME() + 1);
        uint256[] memory ids = _pair(1, 0);
        vm.prank(keeper);
        assertEq(manager.claimMaturedPositions(ids, receiver), 3000 ether);
        _assertAccounting();
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

    function testCreationFailureLeavesAccountingAndAllowanceUnchanged() external {
        vm.expectRevert();
        vm.prank(strategy);
        manager.createPosition(0);
        vm.expectRevert();
        vm.prank(strategy);
        manager.createPosition(1000 ether);
        assertEq(staking.stakesLength(address(manager)), 0);
        assertEq(rail.allowance(address(manager), address(staking)), 0);
        _assertAccounting();
    }

    function testPauseBlocksCreationAndQueueButAllowsClaims() external {
        _create(1000 ether);
        _create(2000 ether);
        _queue(0);
        manager.pause();
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(strategy);
        manager.createPosition(1 ether);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(keeper);
        manager.queuePosition(1);
        vm.warp(block.timestamp + staking.STAKE_LOCKTIME() + 1);
        _claim(0);
        _assertAccounting();
        manager.unpause();
        _queue(1);
        _assertAccounting();
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

    function testRewardsAuthorizationAndZeroAddresses() external {
        IERC20[] memory tokens = new IERC20[](0);
        uint256[] memory hints = new uint256[](0);
        _expectRole(strategy, manager.KEEPER_ROLE());
        manager.claimRewards(IRailgunGovernorRewards(address(0)), tokens, 0, 0, hints, receiver);
        manager.grantRole(manager.KEEPER_ROLE(), keeper);
        vm.expectRevert(RailStakePositionManager.ZeroAddress.selector);
        vm.prank(keeper);
        manager.claimRewards(IRailgunGovernorRewards(address(0)), tokens, 0, 0, hints, receiver);
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

    function _create(uint256 amount) internal returns (uint256 id) {
        deal(address(rail), address(manager), rail.balanceOf(address(manager)) + amount);
        funded += amount;
        vm.prank(strategy);
        id = manager.createPosition(amount);
    }

    function _queue(uint256 id) internal {
        vm.prank(keeper);
        manager.queuePosition(id);
    }

    function _claim(uint256 id) internal {
        vm.prank(keeper);
        manager.claimPosition(id, receiver);
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
        uint256 active;
        uint256 queued;
        uint256 claimed;
        uint256 count = staking.stakesLength(address(manager));
        uint256[] memory ids = manager.activeStakeIdsList();
        bool[] memory seen = new bool[](count);
        assertEq(ids.length, manager.activePositionCount());
        for (uint256 i = 0; i < ids.length; i++) {
            assertLt(ids[i], count);
            assertFalse(seen[ids[i]], "duplicate active ID");
            seen[ids[i]] = true;
        }
        for (uint256 i = 0; i < count; i++) {
            (, uint256 amount,, uint256 locktime, uint256 claimedTime) = staking.stakes(address(manager), i);
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
