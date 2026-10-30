// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RailSystemFixture} from "../utils/RailSystemFixture.sol";
import {StakedRailSupplyHook} from "../../src/governance/StakedRailSupplyHook.sol";
import {IHooks} from "@yieldnest-vault/interface/IHooks.sol";
import {IVault} from "@yieldnest-vault/interface/IVault.sol";

contract StakedRailSupplyHookTest is RailSystemFixture {
    StakedRailSupplyHook internal hook;
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.warp(100 days);
        _deploySystem();
        d.strategy.grantRole(d.strategy.HOOKS_MANAGER_ROLE(), address(this));
        hook = new StakedRailSupplyHook(IVault(address(d.strategy)));
    }

    function _install() internal {
        d.strategy.setHooks(address(hook));
        hook.checkpoint();
    }

    function testInitializeExistingSupplyDoesNotInventEarlierHistory() external {
        _deposit(alice, 1000 ether);
        _install();
        assertEq(hook.historyStartedAt(), block.timestamp);
        assertEq(hook.totalSupplyBefore(block.timestamp), 0);
        vm.warp(block.timestamp + 1);
        assertEq(hook.totalSupplyBefore(block.timestamp), 1000 ether);
        uint256 start = hook.historyStartedAt();
        hook.checkpoint();
        assertEq(hook.historyStartedAt(), start);
    }

    function testRecordsDepositMintRedeemAndWithdrawPaths() external {
        _install();
        _bootstrapSystem();
        vm.warp(block.timestamp + 1);
        uint256 first = block.timestamp;
        assertEq(hook.totalSupplyBefore(first), 8000 ether);
        _deposit(alice, 1000 ether);
        rail.mint(alice, 1000 ether);
        vm.startPrank(alice);
        rail.approve(address(d.strategy), 1000 ether);
        d.strategy.mint(1000 ether, alice);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
        uint256 second = block.timestamp;
        assertEq(hook.totalSupplyBefore(second), 10_000 ether);
        // One queued chunk funds both the processor redeem and a direct asset withdrawal.
        _exit(alice, 100 ether, 1);
        vm.prank(alice);
        d.strategy.withdrawAsset(address(d.qRail), 100 ether, alice, alice);
        vm.warp(block.timestamp + 1);
        assertEq(hook.totalSupplyBefore(block.timestamp), 9800 ether);
        assertEq(hook.totalSupplyBefore(first), 8000 ether);
        assertEq(hook.totalSupplyBefore(second), 10_000 ether);
        d.strategy.processAccounting();
        hook.assertActive();
    }

    function testUninitializedHookCannotBeUsedOrInitializedBeforeAttachment() external {
        vm.expectRevert(StakedRailSupplyHook.InactiveHook.selector);
        hook.checkpoint();
        d.strategy.setHooks(address(hook));
        vm.expectRevert(StakedRailSupplyHook.HistoryNotStarted.selector);
        hook.totalSupplyBefore(block.timestamp);
        rail.mint(alice, 1000 ether);
        vm.startPrank(alice);
        rail.approve(address(d.strategy), 1000 ether);
        vm.expectRevert();
        d.strategy.deposit(1000 ether, alice);
        vm.stopPrank();
        hook.checkpoint();
        vm.prank(alice);
        d.strategy.deposit(1000 ether, alice);
        hook.assertActive();
    }

    function testCallbacksCannotBeForgedAndConfigurationCannotBeDisabled() external {
        _install();
        IHooks.DepositParams memory params;
        vm.expectRevert(IHooks.CallerNotVault.selector);
        hook.afterDeposit(params);
        IHooks.Config memory config;
        vm.expectRevert(StakedRailSupplyHook.ImmutableConfig.selector);
        hook.setConfig(config);
        vm.expectRevert();
        d.strategy.mintShares(alice, 1000 ether);
    }

    function testDetachedOrMismatchedHistoryCannotBeReadOrRepaired() external {
        _install();
        _deposit(alice, 1000 ether);
        vm.warp(block.timestamp + 1);
        d.strategy.setHooks(address(0));
        vm.expectRevert(StakedRailSupplyHook.InactiveHook.selector);
        hook.totalSupplyBefore(block.timestamp);
        _deposit(alice, 1000 ether);
        d.strategy.setHooks(address(hook));
        vm.expectRevert(StakedRailSupplyHook.IncompleteHistory.selector);
        hook.checkpoint();
        vm.expectRevert(StakedRailSupplyHook.IncompleteHistory.selector);
        hook.totalSupplyBefore(block.timestamp);
    }

    function testFuzzRecordedSupplyMatchesActualSupply(uint256 depositAmount, uint256 mintShares) external {
        depositAmount = bound(depositAmount, 1, 1_000_000 ether);
        mintShares = bound(mintShares, 1, 1_000_000 ether);
        _install();
        _deposit(alice, depositAmount);
        rail.mint(alice, mintShares);
        vm.startPrank(alice);
        rail.approve(address(d.strategy), mintShares);
        d.strategy.mint(mintShares, alice);
        d.strategy.transfer(address(0xBEEF), 1);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
        assertEq(hook.totalSupplyBefore(block.timestamp), depositAmount + mintShares);
    }
}
