// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVault} from "@yieldnest-vault/interface/IVault.sol";
import {BeaconProxyFactory} from "@yieldnest-vault-withdrawals/BeaconProxyFactory.sol";
import {WithdrawalRequest} from "@yieldnest-vault-withdrawals/WithdrawalRequest.sol";
import {IBag} from "@yieldnest-vault-withdrawals/interface/IBag.sol";

import {QueuedRailStrategy} from "../../src/core/QueuedRailStrategy.sol";
import {StakedRailStrategy} from "../../src/core/StakedRailStrategy.sol";
import {StakedRailProcessor} from "../../src/processors/StakedRailProcessor.sol";
import {QueuedRailProcessor} from "../../src/processors/QueuedRailProcessor.sol";
import {IRailgunStaking} from "../../src/railgun/IRailgunStaking.sol";
import {RailStakePositionManager} from "../../src/core/RailStakePositionManager.sol";
import {BaseWithdrawer} from "@yieldnest-vault-withdrawals/withdrawers/BaseWithdrawer.sol";
import {SingleAssetFIFOResolver} from "../../src/withdrawals/SingleAssetFIFOResolver.sol";

import {RailStrategyDeployer} from "../../script/RailStrategyDeployer.sol";
import {RailRewardsProcessor} from "../../src/processors/RailRewardsProcessor.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract StakedRailWithdrawalIntegrationTest is Test {
    address internal constant RAILGUN_STAKING = 0xEE6A649Aa3766bD117e12C161726b693A1B2Ee20;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    IERC20 internal rail;
    IRailgunStaking internal staking;
    QueuedRailStrategy internal qRail;
    RailStakePositionManager internal manager;
    StakedRailStrategy internal strategy;
    BeaconProxyFactory internal bagFactory;
    WithdrawalRequest internal requests;
    BaseWithdrawer internal withdrawer;
    SingleAssetFIFOResolver internal resolver;
    QueuedRailProcessor internal queuedRailProcessor;
    StakedRailProcessor internal processor;

    RailStrategyDeployer internal deployer;
    RailRewardsProcessor internal rewardsProcessor;

    function setUp() external {
        staking = IRailgunStaking(RAILGUN_STAKING);
        rail = IERC20(staking.stakingToken());

        deployer = new RailStrategyDeployer(_config(address(this), true));
        RailStrategyDeployer.Deployed memory result = deployer.deploy();
        manager = result.manager;
        qRail = result.qRail;
        strategy = result.strategy;
        bagFactory = result.bagFactory;
        requests = result.withdrawalRequest;
        withdrawer = result.withdrawer;
        resolver = result.resolver;
        queuedRailProcessor = result.queuedRailProcessor;
        processor = result.processor;
        rewardsProcessor = result.rewardsProcessor;
    }

    function _config(address admin, bool unpause) internal view returns (RailStrategyDeployer.Config memory config) {
        address[] memory tokens = new address[](1);
        tokens[0] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        config = RailStrategyDeployer.Config({
            admin: admin,
            rail: address(rail),
            staking: address(staking),
            governorRewards: 0xA02782CE1bF85f56f8cC7C0E66e61299Ac75c86f,
            rewardTokens: tokens,
            nextRewardClaimInterval: 0,
            stakeChunkSize: 1000 ether,
            unpause: unpause
        });
    }

    function testFullStakedRailToRequestNftToRailClaimFlow() external {
        assertEq(address(staking), RAILGUN_STAKING);
        assertEq(staking.STAKE_LOCKTIME(), 30 days);
        assertEq(staking.stakingToken(), address(rail));

        _deposit(alice, 5000 ether);

        assertEq(processor.rebalanceStaking(10), 5);
        assertEq(manager.activeRail().totalSupply(), 5000 ether);
        assertEq(rail.balanceOf(address(strategy)), 0);

        vm.startPrank(alice);
        strategy.approve(address(processor), 1500 ether);
        uint256 qRailAmount = processor.exitToQueuedRail(1500 ether, alice, 2);
        qRail.approve(address(requests), qRailAmount);
        uint256 requestId = requests.requestWithdrawal(qRailAmount, alice, "integration");
        requests.transferFrom(alice, bob, requestId);
        vm.stopPrank();

        assertEq(qRailAmount, 1500 ether);
        assertEq(strategy.balanceOf(alice), 3500 ether);
        assertEq(qRail.balanceOf(address(requests)), 1500 ether);
        assertEq(qRail.balanceOf(address(strategy)), 500 ether);
        assertEq(requests.ownerOf(requestId), bob);
        assertEq(manager.activeRail().totalSupply(), 3000 ether);
        assertEq(manager.unlockedRail().totalSupply(), 2000 ether);

        uint256[] memory stakeIds = new uint256[](2);
        stakeIds[0] = 0;
        stakeIds[1] = 1;
        vm.warp(block.timestamp + 30 days + 1);
        assertEq(queuedRailProcessor.claimMaturedPositions(stakeIds), 2000 ether);
        assertEq(rail.balanceOf(address(qRail)), 2000 ether);

        vm.prank(bob);
        assertEq(resolver.resolveRequests(1), 1);
        WithdrawalRequest.Request memory request = requests.requests(requestId);
        assertEq(request.amountLocked, 0);
        assertEq(rail.balanceOf(request.bag), 1500 ether);
        assertEq(rail.balanceOf(address(qRail)), 500 ether);
        assertEq(qRail.balanceOf(address(requests)), 0);
        assertEq(qRail.balanceOf(address(strategy)), 500 ether);

        address[] memory assets = new address[](1);
        assets[0] = address(rail);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1500 ether;

        vm.prank(bob);
        IBag(request.bag).claim(assets, payable(bob), amounts);
        assertEq(rail.balanceOf(bob), 1500 ether);
        assertEq(rail.balanceOf(request.bag), 0);

        vm.prank(bob);
        requests.burn(requestId);
        assertFalse(requests.requestExists(requestId));
    }

    function testDeployerConfiguresRolesAndRelinquishesControl() external view {
        address bootstrap = address(deployer);
        assertTrue(deployer.deployed());
        assertFalse(strategy.paused());
        assertTrue(qRail.getHasAllocator());
        assertEq(processor.stakeChunkSize(), 1000 ether);
        assertTrue(manager.hasRole(manager.CREATOR_ROLE(), address(strategy)));
        assertTrue(manager.hasRole(manager.QUEUER_ROLE(), address(strategy)));
        assertTrue(manager.hasRole(manager.CLAIMER_ROLE(), address(qRail)));
        assertTrue(manager.hasRole(manager.KEEPER_ROLE(), address(rewardsProcessor)));
        assertTrue(manager.hasRole(manager.PAUSER_ROLE(), address(this)));
        assertTrue(strategy.hasRole(strategy.PROCESSOR_ROLE(), address(processor)));
        assertTrue(qRail.hasRole(qRail.PROCESSOR_ROLE(), address(queuedRailProcessor)));
        assertTrue(qRail.hasRole(qRail.ALLOCATOR_ROLE(), address(strategy)));
        assertTrue(qRail.hasRole(qRail.ALLOCATOR_ROLE(), address(withdrawer)));
        assertTrue(requests.hasRole(requests.RESOLVER_ROLE(), address(resolver)));
        assertTrue(requests.hasRole(requests.CONFIGURATION_MANAGER_ROLE(), address(this)));
        assertTrue(bagFactory.hasRole(bagFactory.CREATOR_ROLE(), address(requests)));
        assertTrue(bagFactory.hasRole(bagFactory.IMPLEMENTATION_MANAGER_ROLE(), address(this)));
        assertTrue(queuedRailProcessor.hasRole(queuedRailProcessor.KEEPER_ROLE(), address(this)));

        assertFalse(strategy.hasRole(strategy.PROCESSOR_MANAGER_ROLE(), bootstrap));
        assertFalse(strategy.hasRole(strategy.ASSET_MANAGER_ROLE(), bootstrap));
        assertFalse(strategy.hasRole(strategy.PROVIDER_MANAGER_ROLE(), bootstrap));
        assertFalse(strategy.getHasAllocator());
        assertEq(strategy.getAssets().length, 3);
        assertEq(strategy.asset(), address(rail));
        assertTrue(strategy.getAsset(address(rail)).active);
        assertFalse(strategy.getAsset(address(qRail)).active);
        assertFalse(strategy.getAsset(address(manager.activeRail())).active);
        assertFalse(strategy.getAssetWithdrawable(address(rail)));
        assertTrue(strategy.getAssetWithdrawable(address(qRail)));
        assertFalse(strategy.getAssetWithdrawable(address(manager.activeRail())));
        assertFalse(strategy.hasRole(strategy.UNPAUSER_ROLE(), bootstrap));
        assertFalse(qRail.hasRole(qRail.PROCESSOR_MANAGER_ROLE(), bootstrap));
        assertFalse(qRail.hasRole(qRail.ASSET_MANAGER_ROLE(), bootstrap));
        assertFalse(qRail.hasRole(qRail.ALLOCATOR_MANAGER_ROLE(), bootstrap));
        assertFalse(qRail.hasRole(qRail.PROVIDER_MANAGER_ROLE(), bootstrap));
        assertEq(qRail.getAssets().length, 2);
        assertEq(qRail.asset(), address(rail));
        assertFalse(qRail.getAsset(address(rail)).active);
        assertTrue(qRail.getAsset(address(manager.unlockedRail())).active);
        assertTrue(qRail.getAssetWithdrawable(address(rail)));
        assertFalse(qRail.getAssetWithdrawable(address(manager.unlockedRail())));
        assertFalse(requests.hasRole(requests.RESOLVER_ROLE(), bootstrap));
        assertFalse(requests.hasRole(requests.CONFIGURATION_MANAGER_ROLE(), bootstrap));
        assertFalse(bagFactory.hasRole(bagFactory.CREATOR_ROLE(), bootstrap));
        assertFalse(requests.hasRole(requests.RESOLVER_ROLE(), address(this)));

        address[8] memory components = [
            address(manager),
            address(strategy),
            address(qRail),
            address(bagFactory),
            address(requests),
            address(processor),
            address(queuedRailProcessor),
            address(rewardsProcessor)
        ];
        for (uint256 i; i < components.length; i++) {
            assertTrue(IAccessControl(components[i]).hasRole(bytes32(0), address(this)));
            assertFalse(IAccessControl(components[i]).hasRole(bytes32(0), bootstrap));
        }
        address[5] memory proxies =
            [address(strategy), address(qRail), address(bagFactory), address(requests), address(withdrawer)];
        for (uint256 i; i < proxies.length; i++) {
            address proxyAdmin =
                address(uint160(uint256(vm.load(proxies[i], bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)))));
            assertEq(Ownable(proxyAdmin).owner(), address(this));
        }
    }

    function testDeployerIsSingleUseAndOperatorOnly() external {
        vm.expectRevert(RailStrategyDeployer.OnlyOperator.selector);
        vm.prank(alice);
        deployer.deploy();
        vm.expectRevert(RailStrategyDeployer.AlreadyDeployed.selector);
        deployer.deploy();
    }

    function testDeploymentFailureRollsBackSingleUseFlag() external {
        RailStrategyDeployer.Config memory config = _config(address(this), true);
        config.stakeChunkSize = 0;
        RailStrategyDeployer another = new RailStrategyDeployer(config);
        vm.expectRevert(StakedRailProcessor.InvalidStakeChunkSize.selector);
        another.deploy();
        assertFalse(another.deployed());
    }

    function testDeployerRejectsZeroAdmin() external {
        RailStrategyDeployer.Config memory config = _config(address(0), false);
        vm.expectRevert(RailStrategyDeployer.InvalidAdmin.selector);
        new RailStrategyDeployer(config);
    }

    function testDeployerCanHandControlToDifferentAdminAndLeavePaused() external {
        RailStrategyDeployer another = new RailStrategyDeployer(_config(bob, false));
        RailStrategyDeployer.Deployed memory result = another.deploy();
        assertTrue(result.strategy.paused());
        assertTrue(result.strategy.hasRole(bytes32(0), bob));
        assertFalse(result.strategy.hasRole(bytes32(0), address(this)));
        assertFalse(result.strategy.hasRole(bytes32(0), address(another)));
        assertTrue(result.strategy.hasRole(result.strategy.UNPAUSER_ROLE(), bob));
        vm.prank(bob);
        result.strategy.unpause();
        assertFalse(result.strategy.paused());
    }

    function testDeployedRulesRestrictApprovalAndClaimRecipients() external {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(rail);
        data[0] = abi.encodeCall(IERC20.approve, (alice, 1));
        vm.expectRevert(abi.encodeWithSignature("AddressNotInAllowlist(address)", alice));
        vm.prank(address(processor));
        strategy.processor(targets, values, data);
        targets[0] = address(manager);
        data[0] = abi.encodeCall(RailStakePositionManager.claimPosition, (0, alice));
        vm.expectRevert(abi.encodeWithSignature("AddressNotInAllowlist(address)", alice));
        vm.prank(address(queuedRailProcessor));
        qRail.processor(targets, values, data);
    }

    function testResolverUsesLiveRateAndPreservesFifoAfterDonation() external {
        _deposit(alice, 5000 ether);
        processor.rebalanceStaking(5);
        vm.startPrank(alice);
        strategy.approve(address(processor), 2000 ether);
        processor.exitToQueuedRail(2000 ether, alice, 2);
        qRail.approve(address(requests), 2000 ether);
        uint256 first = requests.requestWithdrawal(1500 ether, alice, "");
        uint256 second = requests.requestWithdrawal(500 ether, alice, "");
        vm.stopPrank();

        deal(address(rail), bob, 500 ether + 7);
        vm.prank(bob);
        rail.transfer(address(qRail), 500 ether + 7);
        uint256 partialBurn = qRail.previewWithdraw(500 ether + 7);
        vm.prank(bob);
        assertEq(resolver.resolveRequests(2), 0);
        assertEq(requests.requests(first).amountLocked, 1500 ether - partialBurn);
        assertEq(rail.balanceOf(requests.requests(first).bag), 500 ether + 7);
        assertEq(requests.requests(second).amountLocked, 500 ether);
        assertEq(rail.balanceOf(requests.requests(second).bag), 0);
        assertEq(resolver.nextRequestToResolve(), first);

        vm.warp(block.timestamp + staking.STAKE_LOCKTIME() + 1);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
        queuedRailProcessor.claimMaturedPositions(ids);
        for (uint256 id = first; id <= second; id++) {
            uint256 locked = requests.requests(id).amountLocked;
            uint256 assets = qRail.previewRedeem(locked);
            assertGt(assets, locked);
            uint256 bagBefore = rail.balanceOf(requests.requests(id).bag);
            uint256 supplyBefore = qRail.totalSupply();
            vm.prank(bob);
            assertEq(resolver.resolveRequests(1), 1);
            assertEq(requests.requests(id).amountLocked, 0);
            assertEq(qRail.totalSupply(), supplyBefore - locked);
            assertEq(rail.balanceOf(requests.requests(id).bag), bagBefore + assets);
            assertEq(resolver.nextRequestToResolve(), id + 1);
        }
        assertEq(qRail.balanceOf(address(requests)), 0);
    }

    function testQueueAfterDonationDepositsReceiptsAtLiveRate() external {
        _deposit(alice, 3000 ether);
        processor.rebalanceStaking(3);
        vm.startPrank(alice);
        strategy.approve(address(processor), 1000 ether);
        processor.exitToQueuedRail(1000 ether, alice, 1);
        vm.stopPrank();

        deal(address(rail), bob, 500 ether);
        vm.prank(bob);
        assertTrue(rail.transfer(address(qRail), 500 ether));
        uint256 holderAssets = qRail.convertToAssets(qRail.balanceOf(alice));
        uint256 expectedShares = qRail.previewDepositAsset(address(manager.unlockedRail()), 1000 ether);
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(strategy);
        data[0] = abi.encodeCall(StakedRailStrategy.queuePosition, ());
        vm.prank(address(processor));
        strategy.processor(targets, values, data);
        assertEq(qRail.balanceOf(address(strategy)), expectedShares);
        assertLt(expectedShares, 1000 ether);
        assertGe(qRail.convertToAssets(qRail.balanceOf(alice)), holderAssets);
        assertEq(qRail.totalAssets(), 2500 ether);
        assertEq(manager.unlockedRail().balanceOf(address(qRail)), 2000 ether);

        vm.startPrank(alice);
        qRail.approve(address(requests), 1000 ether);
        uint256 id = requests.requestWithdrawal(1000 ether, alice, "");
        vm.stopPrank();
        vm.warp(block.timestamp + staking.STAKE_LOCKTIME() + 1);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
        queuedRailProcessor.claimMaturedPositions(ids);
        assertEq(manager.unlockedRail().totalSupply(), 0);
        assertEq(qRail.totalAssets(), 2500 ether);
        uint256 payout = qRail.previewRedeem(1000 ether);
        assertGe(payout, holderAssets);
        assertEq(resolver.resolveRequests(1), 1);
        assertEq(requests.requests(id).amountLocked, 0);
        assertEq(rail.balanceOf(requests.requests(id).bag), payout);
    }

    function _deposit(address account, uint256 amount) internal {
        deal(address(rail), account, amount);
        vm.startPrank(account);
        rail.approve(address(strategy), amount);
        strategy.deposit(amount, account);
        vm.stopPrank();
    }
}
