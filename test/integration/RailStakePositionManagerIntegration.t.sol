// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRailgunStaking} from "../../src/railgun/IRailgunStaking.sol";
import {RailStakePositionManager} from "../../src/railgun/RailStakePositionManager.sol";

contract RailStakePositionManagerIntegrationTest is Test {
    address internal constant RAILGUN_STAKING = 0xEE6A649Aa3766bD117e12C161726b693A1B2Ee20;

    address internal strategy = makeAddr("strategy");
    address internal keeper = makeAddr("keeper");
    address internal receiver = makeAddr("receiver");

    bool internal forkAvailable;
    IERC20 internal rail;
    IRailgunStaking internal staking;
    RailStakePositionManager internal manager;

    function setUp() external {
        string memory rpcUrl = vm.envOr("ETH_MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            return;
        }

        uint256 forkBlock = vm.envOr("RAIL_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork(rpcUrl, forkBlock);
        }
        forkAvailable = true;

        staking = IRailgunStaking(RAILGUN_STAKING);
        rail = IERC20(staking.stakingToken());
        manager = new RailStakePositionManager(address(this), rail, staking);
        manager.setStrategy(strategy);
        manager.grantRole(manager.KEEPER_ROLE(), keeper);
    }

    function testCreateQueueAndClaimRealRailgunStake() external {
        vm.skip(!forkAvailable, "ETH_MAINNET_RPC_URL is not set");

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
        vm.skip(!forkAvailable, "ETH_MAINNET_RPC_URL is not set");

        vm.expectRevert();
        vm.prank(keeper);
        manager.queuePosition(0);

        vm.expectRevert();
        vm.prank(keeper);
        manager.claimPosition(0, receiver);
        assertEq(manager.activePrincipal(), 0);
        assertEq(manager.queuedPrincipal(), 0);
    }
}
