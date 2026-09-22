// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IVault} from "@yieldnest-vault/interface/IVault.sol";
import {IValidator} from "@yieldnest-vault/interface/IValidator.sol";
import {Bag} from "@yieldnest-vault-withdrawals/Bag.sol";
import {BeaconProxyFactory} from "@yieldnest-vault-withdrawals/BeaconProxyFactory.sol";
import {WithdrawalRequest} from "@yieldnest-vault-withdrawals/WithdrawalRequest.sol";
import {IBag} from "@yieldnest-vault-withdrawals/interface/IBag.sol";
import {MinAmountRequestPolicy} from "@yieldnest-vault-withdrawals/policies/MinAmountRequestPolicy.sol";

import {QueuedRailStrategy} from "../../src/core/QueuedRailStrategy.sol";
import {StakedRailStrategy} from "../../src/core/StakedRailStrategy.sol";
import {StakedRailProcessor} from "../../src/processors/StakedRailProcessor.sol";
import {QueuedRailProcessor} from "../../src/processors/QueuedRailProcessor.sol";
import {IRailgunStaking} from "../../src/railgun/IRailgunStaking.sol";
import {RailStakePositionManager} from "../../src/core/RailStakePositionManager.sol";
import {BaseWithdrawer} from "@yieldnest-vault-withdrawals/withdrawers/BaseWithdrawer.sol";
import {SingleAssetFIFOResolver} from "../../src/withdrawals/SingleAssetFIFOResolver.sol";

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

    function setUp() external {
        staking = IRailgunStaking(RAILGUN_STAKING);
        rail = IERC20(staking.stakingToken());

        manager = new RailStakePositionManager(address(this), rail, staking);

        QueuedRailStrategy qRailImplementation = new QueuedRailStrategy();
        StakedRailStrategy strategyImplementation = new StakedRailStrategy();
        qRail = QueuedRailStrategy(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(qRailImplementation),
                        makeAddr("qRailProxyAdmin"),
                        abi.encodeCall(QueuedRailStrategy.initialize, (address(this), address(rail), manager))
                    )
                )
            )
        );

        strategy = StakedRailStrategy(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(strategyImplementation),
                        makeAddr("stRailProxyAdmin"),
                        abi.encodeCall(
                            StakedRailStrategy.initialize, (address(this), address(rail), manager, qRail)
                        )
                    )
                )
            )
        );

        Bag bagImplementation = new Bag();
        BeaconProxyFactory bagFactoryImplementation = new BeaconProxyFactory();
        bagFactory = BeaconProxyFactory(
            address(
                new TransparentUpgradeableProxy(
                    address(bagFactoryImplementation),
                    makeAddr("bagFactoryProxyAdmin"),
                    abi.encodeCall(
                        BeaconProxyFactory.initialize,
                        (address(bagImplementation), address(this), address(this), address(this))
                    )
                )
            )
        );

        MinAmountRequestPolicy requestPolicy = new MinAmountRequestPolicy(1);
        WithdrawalRequest requestImplementation = new WithdrawalRequest();
        requests = WithdrawalRequest(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(requestImplementation),
                        makeAddr("requestProxyAdmin"),
                        abi.encodeCall(
                            WithdrawalRequest.initialize,
                            (
                                address(qRail),
                                address(this),
                                address(this),
                                address(this),
                                address(this),
                                address(bagFactory),
                                address(this),
                                address(requestPolicy),
                                uint256(1024)
                            )
                        )
                    )
                )
            )
        );

        BaseWithdrawer withdrawerImplementation = new BaseWithdrawer();
        withdrawer = BaseWithdrawer(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(withdrawerImplementation),
                        makeAddr("withdrawerProxyAdmin"),
                        abi.encodeCall(BaseWithdrawer.initialize, (address(qRail), address(requests)))
                    )
                )
            )
        );

        resolver =
            new SingleAssetFIFOResolver(IERC4626(address(qRail)), requests);
        processor =
            new StakedRailProcessor(address(this), strategy, 1000 ether);

        queuedRailProcessor = new QueuedRailProcessor(address(this), qRail);
        queuedRailProcessor.grantRole(queuedRailProcessor.KEEPER_ROLE(), address(this));

        manager.grantRole(manager.CREATOR_ROLE(), address(strategy));
        strategy.grantRole(strategy.PROCESSOR_ROLE(), address(processor));
        strategy.grantRole(strategy.PROCESSOR_MANAGER_ROLE(), address(this));
        qRail.grantRole(qRail.PROCESSOR_ROLE(), address(queuedRailProcessor));
        qRail.grantRole(qRail.PROCESSOR_MANAGER_ROLE(), address(this));
        _setProcessorRules();
        manager.grantRole(manager.CLAIMER_ROLE(), address(qRail));
        manager.grantRole(manager.QUEUER_ROLE(), address(strategy));
        bagFactory.grantRole(bagFactory.CREATOR_ROLE(), address(requests));
        requests.setWithdrawer(address(withdrawer));
        qRail.grantRole(qRail.ALLOCATOR_ROLE(), address(strategy));
        qRail.grantRole(qRail.ALLOCATOR_ROLE(), address(withdrawer));
        requests.grantRole(requests.RESOLVER_ROLE(), address(resolver));
        strategy.grantRole(strategy.UNPAUSER_ROLE(), address(this));
        strategy.unpause();
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

    function _setProcessorRules() internal {
        IVault.FunctionRule memory rule = _emptyRule();
        rule.paramRules = new IVault.ParamRule[](2);
        rule.paramRules[0].paramType = IVault.ParamType.ADDRESS;
        rule.paramRules[0].allowList = new address[](1);
        rule.paramRules[0].allowList[0] = address(manager);
        rule.paramRules[1].paramType = IVault.ParamType.UINT256;
        strategy.setProcessorRule(address(rail), IERC20.approve.selector, rule);
        rule = _emptyRule();
        strategy.setProcessorRule(address(manager), RailStakePositionManager.createPosition.selector, rule);
        strategy.setProcessorRule(address(strategy), StakedRailStrategy.queuePosition.selector, rule);

        rule.paramRules = new IVault.ParamRule[](2);
        rule.paramRules[0].paramType = IVault.ParamType.UINT256;
        rule.paramRules[1].paramType = IVault.ParamType.ADDRESS;
        rule.paramRules[1].allowList = new address[](1);
        rule.paramRules[1].allowList[0] = address(qRail);
        qRail.setProcessorRule(address(manager), RailStakePositionManager.claimPosition.selector, rule);
        rule.paramRules[0].isArray = true;
        qRail.setProcessorRule(address(manager), RailStakePositionManager.claimMaturedPositions.selector, rule);
    }

    function _emptyRule() internal pure returns (IVault.FunctionRule memory rule) {
        rule.isActive = true;
        rule.paramRules = new IVault.ParamRule[](0);
        rule.validator = IValidator(address(0));
    }
}
