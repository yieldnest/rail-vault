// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {MockHookRouter} from "../mocks/MockHookRouter.sol";
import {RailSystemFixture} from "../utils/RailSystemFixture.sol";
import {StakedRailSupplyHook} from "../../src/governance/StakedRailSupplyHook.sol";
import {IHooks} from "@yieldnest-vault/interface/IHooks.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IVault} from "@yieldnest-vault/interface/IVault.sol";

contract StakedRailSupplyHookV2 is StakedRailSupplyHook {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract StakedRailSupplyHookTest is RailSystemFixture {
    StakedRailSupplyHook internal hook;
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.warp(100 days);
        _deploySystem();
        d.strategy.grantRole(d.strategy.HOOKS_MANAGER_ROLE(), address(this));
        hook = StakedRailSupplyHook(
            address(
                new TransparentUpgradeableProxy(
                    address(new StakedRailSupplyHook()),
                    address(this),
                    abi.encodeCall(StakedRailSupplyHook.initialize, (IVault(address(d.strategy))))
                )
            )
        );
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
        _exerciseSupplyChanges();
    }

    function testRecordsSupplyThroughConfiguredHookRouter() external {
        MockHookRouter router = new MockHookRouter(IVault(address(d.strategy)), hook);
        // Setup can seed history before the router is installed.
        hook.checkpoint();
        d.strategy.setHooks(address(router));
        _exerciseSupplyChanges();
        d.strategy.setHooks(address(0));
        IHooks.DepositParams memory params;
        vm.prank(address(router));
        vm.expectRevert(IHooks.CallerNotVault.selector);
        hook.afterDeposit(params);
    }

    function _exerciseSupplyChanges() internal {
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
        vm.warp(block.timestamp + 1);
        assertEq(hook.totalSupplyBefore(block.timestamp), d.strategy.totalSupply());
    }

    function testUninitializedHookCannotRecordSupply() external {
        d.strategy.setHooks(address(hook));
        assertEq(hook.totalSupplyBefore(block.timestamp), 0);
        rail.mint(alice, 1000 ether);
        vm.startPrank(alice);
        rail.approve(address(d.strategy), 1000 ether);
        vm.expectRevert();
        d.strategy.deposit(1000 ether, alice);
        vm.stopPrank();
        hook.checkpoint();
        vm.prank(alice);
        d.strategy.deposit(1000 ether, alice);
        vm.warp(block.timestamp + 1);
        assertEq(hook.totalSupplyBefore(block.timestamp), d.strategy.totalSupply());
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

    function testDetachedHistoryRemainsReadableAndCheckpointDoesNotReconstructGap() external {
        _install();
        _deposit(alice, 1000 ether);
        vm.warp(block.timestamp + 1);
        d.strategy.setHooks(address(0));
        _deposit(alice, 1000 ether);
        vm.warp(block.timestamp + 1);
        uint256 gap = block.timestamp;
        assertEq(hook.totalSupplyBefore(gap), 1000 ether);
        assertEq(d.strategy.totalSupply(), 2000 ether);
        d.strategy.setHooks(address(hook));
        hook.checkpoint();
        vm.warp(block.timestamp + 1);
        assertEq(hook.totalSupplyBefore(block.timestamp), 2000 ether);
        assertEq(hook.totalSupplyBefore(gap), 1000 ether);
    }

    function _proxyAdmin() internal view returns (ProxyAdmin) {
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        return ProxyAdmin(address(uint160(uint256(vm.load(address(hook), slot)))));
    }

    function testUpgradePreservesHistoryAndContinuesRecording() external {
        _install();
        uint256 start = hook.historyStartedAt();
        _deposit(alice, 1000 ether);
        vm.warp(block.timestamp + 1);
        uint256 first = block.timestamp;
        _deposit(alice, 2000 ether);
        vm.warp(block.timestamp + 1);
        uint256 second = block.timestamp;
        address original = address(hook);
        StakedRailSupplyHookV2 next = new StakedRailSupplyHookV2();
        ProxyAdmin admin = _proxyAdmin();
        assertEq(admin.owner(), address(this));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(hook)), address(next), "");
        assertEq(StakedRailSupplyHookV2(address(hook)).version(), 2);
        assertEq(address(hook), original);
        assertEq(address(d.strategy.hooks()), original);
        assertEq(address(hook.VAULT()), address(d.strategy));
        assertEq(hook.historyStartedAt(), start);
        assertEq(hook.totalSupplyBefore(start), 0);
        assertEq(hook.totalSupplyBefore(first), 1000 ether);
        assertEq(hook.totalSupplyBefore(second), 3000 ether);
        _deposit(alice, 500 ether);
        vm.warp(block.timestamp + 1);
        assertEq(hook.totalSupplyBefore(block.timestamp), 3500 ether);
        assertEq(hook.totalSupplyBefore(first), 1000 ether);
        assertEq(hook.totalSupplyBefore(second), 3000 ether);
    }

    function testOnlyProxyAdminOwnerCanUpgrade() external {
        ProxyAdmin admin = _proxyAdmin();
        StakedRailSupplyHook next = new StakedRailSupplyHook();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(hook)), address(next), "");
    }

    function testInitializationIsOneTimeAndImplementationIsDisabled() external {
        StakedRailSupplyHook implementation = new StakedRailSupplyHook();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(IVault(address(d.strategy)));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        hook.initialize(IVault(address(d.qRail)));
        vm.expectRevert(StakedRailSupplyHook.InvalidVault.selector);
        new TransparentUpgradeableProxy(
            address(implementation),
            address(this),
            abi.encodeCall(StakedRailSupplyHook.initialize, (IVault(address(0))))
        );
    }

    function testStateUsesERC7201Namespace() external {
        _install();
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("yieldnest.storage.StakedRailSupplyHook")) - 1))
            & ~bytes32(uint256(0xff));
        assertEq(address(uint160(uint256(vm.load(address(hook), slot)))), address(d.strategy));
        assertEq(uint256(vm.load(address(hook), bytes32(uint256(slot) + 1))), hook.historyStartedAt());
        assertEq(uint256(vm.load(address(hook), bytes32(uint256(slot) + 2))), 1);
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
