// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Bag} from "@yieldnest-vault-withdrawals/Bag.sol";
import {WithdrawalRequest} from "@yieldnest-vault-withdrawals/WithdrawalRequest.sol";
import {BaseWithdrawer} from "@yieldnest-vault-withdrawals/withdrawers/BaseWithdrawer.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {RailStrategyDeployer} from "../../script/RailStrategyDeployer.sol";
import {RailStakePositionManager} from "../../src/core/RailStakePositionManager.sol";
import {RailReceiptToken} from "../../src/core/RailReceiptToken.sol";
import {RailProvider} from "../../src/core/RailProvider.sol";
import {StakedRailStrategy} from "../../src/core/StakedRailStrategy.sol";
import {QueuedRailStrategy} from "../../src/core/QueuedRailStrategy.sol";
import {SingleAssetFIFOResolver} from "../../src/withdrawals/SingleAssetFIFOResolver.sol";
import {BeaconProxyFactory} from "@yieldnest-vault-withdrawals/BeaconProxyFactory.sol";
import {MinAmountRequestPolicy} from "@yieldnest-vault-withdrawals/policies/MinAmountRequestPolicy.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRailgunStaking} from "../mocks/MockRailgunStaking.sol";
import {MockSplitsSwapper} from "../mocks/MockSplitsSwapper.sol";

contract RailManagerV2 is RailStakePositionManager {
    uint256 public upgradeMarker;

    function initializeV2(uint256 marker) external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        upgradeMarker = marker;
    }
}

contract BagV2 is Bag {
    function versionMarker() external pure returns (uint256) {
        return 2;
    }
}

contract RailUpgradeabilityTest is Test {
    bytes32 constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    bytes32 constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    bytes32 constant BEACON_SLOT = bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1);
    address governance = makeAddr("governance");
    address alice = makeAddr("alice");
    MockERC20 rail;
    MockRailgunStaking staking;
    MockSplitsSwapper splits;
    RailStrategyDeployer deployer;
    RailStrategyDeployer.Deployed d;

    function setUp() public {
        rail = new MockERC20("RAIL", "RAIL", 18);
        staking = new MockRailgunStaking(rail);
        splits = new MockSplitsSwapper(governance, address(rail));
        deployer = new RailStrategyDeployer(_config());
        d = deployer.deploy();
    }

    function testDeploymentRequiresExtraRoleGrantBeforeVaultPause() external {
        bytes32 pauser = d.strategy.PAUSER_ROLE();
        assertFalse(d.strategy.hasRole(pauser, governance));
        assertFalse(d.qRail.hasRole(pauser, governance));
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", governance, pauser)
        );
        vm.prank(governance);
        d.strategy.pause();
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", governance, pauser)
        );
        vm.prank(governance);
        d.qRail.pause();
    }

    function testDeploymentAcceptsRewardReceiverOutsideStrategy() external {
        assertEq(d.rewardsProcessor.railReceiver(), governance);
        rail.mint(address(d.manager), 10 ether);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rail));
        vm.prank(alice);
        d.rewardsProcessor.collectTokens(tokens);
        assertEq(rail.balanceOf(governance), 10 ether);
        assertEq(rail.balanceOf(address(d.strategy)), 0);
        assertEq(d.strategy.totalAssets(), 0);
    }

    function _resolverStorageSlot() internal pure returns (bytes32) {
        return
            keccak256(abi.encode(uint256(keccak256("rail.storage.SingleAssetFIFOResolver")) - 1))
                & ~bytes32(uint256(0xff));
    }

    function testResolverUsesERC7201Storage() external view {
        bytes32 slot = _resolverStorageSlot();
        address resolver = address(d.resolver);
        assertEq(address(d.resolver.vault()), address(d.qRail));
        assertEq(address(d.resolver.withdrawalRequest()), address(d.withdrawalRequest));
        assertEq(vm.load(resolver, slot), bytes32(uint256(uint160(address(d.qRail)))));
        assertEq(vm.load(resolver, bytes32(uint256(slot) + 1)), bytes32(uint256(uint160(address(d.withdrawalRequest)))));
        assertEq(vm.load(resolver, bytes32(uint256(slot) + 2)), bytes32(0));
        assertEq(vm.load(resolver, bytes32(0)), bytes32(0));
        assertEq(vm.load(resolver, bytes32(uint256(1))), bytes32(0));
        assertEq(vm.load(resolver, bytes32(uint256(2))), bytes32(0));
    }

    function _config() internal view returns (RailStrategyDeployer.Config memory) {
        return
            RailStrategyDeployer.Config(governance, address(rail), address(staking), address(splits), 1000 ether, true);
    }

    function _proxies(RailStrategyDeployer.Deployed memory s) internal view returns (address[] memory p) {
        p = new address[](9);
        p[0] = address(s.manager);
        p[1] = address(s.manager.activeRail());
        p[2] = address(s.manager.unlockedRail());
        p[3] = address(s.strategy);
        p[4] = address(s.qRail);
        p[5] = address(s.bagFactory);
        p[6] = address(s.withdrawalRequest);
        p[7] = address(s.withdrawer);
        p[8] = address(s.resolver);
    }

    function _implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function _admin(address proxy) internal view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(proxy, ADMIN_SLOT)))));
    }

    function _upgrade(address proxy, address implementation) internal {
        ProxyAdmin admin = _admin(proxy);
        vm.prank(governance);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), implementation, "");
        assertEq(_implementation(proxy), implementation);
    }

    function testProxyTypesAndNonUpgradeableComponents() external view {
        address[] memory proxies = _proxies(d);
        for (uint256 i; i < proxies.length; ++i) {
            assertGt(_implementation(proxies[i]).code.length, 0);
            assertEq(_admin(proxies[i]).owner(), governance);
        }
        assertEq(_implementation(address(d.processor)), address(0));
        assertEq(_implementation(d.strategy.provider()), address(0));
        assertEq(_implementation(d.qRail.provider()), address(0));
        assertEq(address(_admin(d.strategy.provider())), address(0));
        assertEq(address(_admin(d.qRail.provider())), address(0));
        RailProvider provider = RailProvider(d.strategy.provider());
        assertEq(provider.rail(), address(rail));
        assertEq(provider.activeRail(), address(d.manager.activeRail()));
        assertEq(provider.queuedRail(), address(d.qRail));
        assertEq(provider.unlockedRail(), address(0));
        assertEq(provider.rate(), 1 ether);
        RailProvider queuedProvider = RailProvider(d.qRail.provider());
        assertEq(queuedProvider.rail(), address(rail));
        assertEq(queuedProvider.unlockedRail(), address(d.manager.unlockedRail()));
        assertEq(queuedProvider.activeRail(), address(0));
        assertEq(queuedProvider.queuedRail(), address(0));
        assertEq(_implementation(address(d.queuedRailProcessor)), address(0));
        assertEq(_implementation(address(d.rewardsProcessor)), address(0));
        assertEq(_implementation(address(d.withdrawalRequest.requestPolicy())), address(0));
        assertEq(address(_admin(address(d.withdrawalRequest.requestPolicy()))), address(0));
        assertEq(d.manager.activeRail().manager(), address(d.manager));
        assertEq(d.manager.unlockedRail().manager(), address(d.manager));
        assertTrue(d.manager.hasRole(bytes32(0), governance));
        assertFalse(d.manager.hasRole(bytes32(0), address(deployer)));
        assertFalse(d.bagFactory.hasRole(bytes32(0), address(deployer)));
        assertEq(UpgradeableBeacon(d.bagFactory.beacon()).owner(), address(d.bagFactory));
        assertTrue(d.bagFactory.hasRole(d.bagFactory.IMPLEMENTATION_MANAGER_ROLE(), governance));
    }

    function testInitializersLockedOnImplementationsAndProxies() external {
        address[] memory proxies = _proxies(d);
        bytes[] memory calls = new bytes[](9);
        calls[0] = abi.encodeCall(RailStakePositionManager.initialize, (governance, rail, staking, governance));
        calls[1] = abi.encodeCall(RailReceiptToken.initialize, ("Active RAIL", "aRAIL", 18, address(d.manager)));
        calls[2] = abi.encodeCall(RailReceiptToken.initialize, ("Unlocked RAIL", "uRAIL", 18, address(d.manager)));
        calls[3] = abi.encodeCall(
            StakedRailStrategy.initialize,
            (governance, "Staked RAIL", "stRAIL", 18, true, false, true, 0, d.manager, d.qRail)
        );
        calls[4] = abi.encodeCall(
            QueuedRailStrategy.initialize, (governance, "Queued RAIL", "qRAIL", 18, false, false, true, 0)
        );
        calls[5] = abi.encodeCall(
            BeaconProxyFactory.initialize, (d.bagFactory.implementation(), governance, governance, governance)
        );
        calls[6] = abi.encodeCall(
            WithdrawalRequest.initialize,
            (
                address(d.qRail),
                governance,
                governance,
                governance,
                governance,
                address(d.bagFactory),
                governance,
                address(d.withdrawalRequest.requestPolicy()),
                1024
            )
        );
        calls[7] = abi.encodeCall(BaseWithdrawer.initialize, (address(d.qRail), address(d.withdrawalRequest)));
        calls[8] = abi.encodeCall(SingleAssetFIFOResolver.initialize, (IERC4626(address(d.qRail)), d.withdrawalRequest));
        for (uint256 i; i < proxies.length; ++i) {
            _assertLocked(proxies[i], calls[i]);
            _assertLocked(_implementation(proxies[i]), calls[i]);
        }
        _assertLocked(d.bagFactory.implementation(), abi.encodeCall(Bag.initialize, (address(d.withdrawalRequest), 0)));
    }

    function _assertLocked(address target, bytes memory data) internal {
        (bool ok, bytes memory reason) = target.call(data);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
    }

    function testOnlyGovernanceCanUpgrade() external {
        address[] memory proxies = _proxies(d);
        for (uint256 i; i < proxies.length; ++i) {
            ProxyAdmin admin = _admin(proxies[i]);
            address implementation = _implementation(proxies[i]);
            vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
            vm.prank(alice);
            admin.upgradeAndCall(ITransparentUpgradeableProxy(proxies[i]), implementation, "");
        }
    }

    function _createPendingWithdrawal() internal returns (uint256 id, address bag) {
        rail.mint(alice, 3000 ether);
        vm.startPrank(alice);
        rail.approve(address(d.strategy), 3000 ether);
        d.strategy.deposit(3000 ether, alice);
        vm.stopPrank();
        d.processor.rebalanceStaking(3);
        vm.startPrank(alice);
        d.strategy.approve(address(d.processor), 1000 ether);
        uint256 queued = d.processor.exitToQueuedRail(1000 ether, alice, 1);
        d.qRail.approve(address(d.withdrawalRequest), queued);
        id = d.withdrawalRequest.requestWithdrawal(queued, alice, "");
        vm.stopPrank();
        bag = d.withdrawalRequest.requests(id).bag;
    }

    function testUpgradeAllContractsPreservesLivePositionsAndWithdrawal() external {
        (uint256 id, address bag) = _createPendingWithdrawal();
        assertEq(address(uint160(uint256(vm.load(bag, BEACON_SLOT)))), d.bagFactory.beacon());
        assertEq(address(_admin(bag)), address(0));
        _assertLocked(bag, abi.encodeCall(Bag.initialize, (address(d.withdrawalRequest), id)));
        RailStrategyDeployer otherDeployer = new RailStrategyDeployer(_config());
        RailStrategyDeployer.Deployed memory other = otherDeployer.deploy();
        address[] memory proxies = _proxies(d);
        address[] memory replacements = _proxies(other);
        for (uint256 i; i < proxies.length; ++i) {
            _upgrade(proxies[i], _implementation(replacements[i]));
        }
        address newBagImplementation = address(new BagV2());
        vm.prank(governance);
        d.bagFactory.upgradeImplementation(newBagImplementation);
        assertEq(BagV2(payable(bag)).versionMarker(), 2);
        assertEq(Bag(payable(bag)).auth(), address(d.withdrawalRequest));
        assertEq(Bag(payable(bag)).id(), id);
        assertEq(d.strategy.balanceOf(alice), 2000 ether);
        assertEq(d.manager.activeRail().totalSupply(), 2000 ether);
        assertEq(d.manager.unlockedRail().totalSupply(), 1000 ether);
        assertEq(d.manager.activeRail().manager(), address(d.manager));
        assertEq(address(d.manager.rail()), address(rail));
        assertEq(address(d.manager.staking()), address(staking));
        assertEq(address(d.strategy.positionManager()), address(d.manager));
        assertEq(d.withdrawalRequest.ownerOf(id), alice);
        assertEq(RailProvider(d.strategy.provider()).getRate(address(rail)), 1 ether);
        assertEq(MinAmountRequestPolicy(address(d.withdrawalRequest.requestPolicy())).minWithdrawalAmount(), 1);
        vm.warp(block.timestamp + 30 days + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.prank(governance);
        d.queuedRailProcessor.claimMaturedPositions(ids);
        d.resolver.resolveRequests(1);
        assertEq(d.resolver.nextRequestToResolve(), 1);
        assertEq(rail.balanceOf(bag), 1000 ether);
        // A second resolver upgrade must preserve the already-advanced FIFO cursor.
        _upgrade(address(d.resolver), address(new SingleAssetFIFOResolver()));
        assertEq(d.resolver.nextRequestToResolve(), 1);
        assertEq(address(d.resolver.vault()), address(d.qRail));
        assertEq(address(d.resolver.withdrawalRequest()), address(d.withdrawalRequest));
        assertEq(vm.load(address(d.resolver), bytes32(uint256(_resolverStorageSlot()) + 2)), bytes32(uint256(1)));
        address[] memory assets = new address[](1);
        assets[0] = address(rail);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000 ether;
        vm.prank(alice);
        Bag(payable(bag)).claim(assets, payable(alice), amounts);
        assertEq(rail.balanceOf(alice), 1000 ether);
        // Remaining active FIFO entries still belong to the original manager address.
        vm.prank(alice);
        d.strategy.approve(address(d.processor), 1000 ether);
        vm.prank(alice);
        d.processor.exitToQueuedRail(1000 ether, alice, 1);
        assertEq(d.manager.activeRail().totalSupply(), 1000 ether);
    }

    function testManagerUpgradeCanAppendStateWithoutResettingPauseOrRoles() external {
        vm.prank(governance);
        d.manager.pause();
        address v2 = address(new RailManagerV2());
        _upgrade(address(d.manager), v2);
        RailManagerV2 manager = RailManagerV2(address(d.manager));
        vm.prank(governance);
        manager.initializeV2(42);
        assertEq(manager.upgradeMarker(), 42);
        assertTrue(manager.paused());
        assertTrue(manager.hasRole(manager.CREATOR_ROLE(), address(d.strategy)));
        assertTrue(manager.hasRole(manager.TOKEN_WITHDRAWER_ROLE(), address(d.rewardsProcessor)));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(governance);
        manager.initializeV2(43);
    }

    function testBeaconUpgradeUpdatesExistingAndFutureBags() external {
        (uint256 id, address bag) = _createPendingWithdrawal();
        address replacement = address(new BagV2());
        UpgradeableBeacon beacon = UpgradeableBeacon(d.bagFactory.beacon());
        vm.expectRevert();
        vm.prank(alice);
        d.bagFactory.upgradeImplementation(replacement);
        vm.expectRevert();
        vm.prank(alice);
        beacon.upgradeTo(replacement);
        vm.prank(governance);
        d.bagFactory.upgradeImplementation(replacement);
        assertEq(BagV2(payable(bag)).versionMarker(), 2);
        assertEq(Bag(payable(bag)).id(), id);
        assertEq(Bag(payable(bag)).auth(), address(d.withdrawalRequest));
        assertEq(d.bagFactory.implementation(), replacement);
        bytes32 creatorRole = d.bagFactory.CREATOR_ROLE();
        vm.prank(governance);
        d.bagFactory.grantRole(creatorRole, address(this));
        address nextBag = d.bagFactory.create(abi.encodeCall(Bag.initialize, (address(d.withdrawalRequest), 123)));
        assertEq(BagV2(payable(nextBag)).versionMarker(), 2);
        assertEq(Bag(payable(nextBag)).id(), 123);
        assertEq(address(uint160(uint256(vm.load(nextBag, BEACON_SLOT)))), d.bagFactory.beacon());
        assertEq(address(_admin(nextBag)), address(0));
    }
}
