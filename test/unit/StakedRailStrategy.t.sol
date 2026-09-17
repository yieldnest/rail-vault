// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IVault} from "@yieldnest-vault/interface/IVault.sol";
import {IValidator} from "@yieldnest-vault/interface/IValidator.sol";
import {Bag} from "@yieldnest-vault-withdrawals/Bag.sol";
import {BeaconProxyFactory} from "@yieldnest-vault-withdrawals/BeaconProxyFactory.sol";
import {WithdrawalRequest} from "@yieldnest-vault-withdrawals/WithdrawalRequest.sol";
import {IBag} from "@yieldnest-vault-withdrawals/interface/IBag.sol";
import {MinAmountRequestPolicy} from "@yieldnest-vault-withdrawals/policies/MinAmountRequestPolicy.sol";

import {QueuedRailStrategy} from "../../src/QueuedRailStrategy.sol";
import {StakedRailStrategy} from "../../src/StakedRailStrategy.sol";
import {StakedRailExitProcessor} from "../../src/processors/StakedRailExitProcessor.sol";
import {StakedRailStakingProcessor} from "../../src/processors/StakedRailStakingProcessor.sol";
import {RailStakePositionManager} from "../../src/railgun/RailStakePositionManager.sol";
import {RailWithdrawer} from "../../src/withdrawals/RailWithdrawer.sol";
import {RailWithdrawalResolver} from "../../src/withdrawals/RailWithdrawalResolver.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRailgunStaking} from "../mocks/MockRailgunStaking.sol";

contract StakedRailStrategyTest is Test {
    address user = makeAddr("user");

    MockERC20 rail;
    MockRailgunStaking staking;
    QueuedRailStrategy qRail;
    RailStakePositionManager manager;
    StakedRailStrategy strategy;
    BeaconProxyFactory bagFactory;
    WithdrawalRequest requests;
    RailWithdrawer withdrawer;
    RailWithdrawalResolver resolver;
    StakedRailStakingProcessor stakingProcessor;
    StakedRailExitProcessor exitProcessor;

    function setUp() external {
        rail = new MockERC20("RAIL", "RAIL", 18);
        staking = new MockRailgunStaking(rail);

        manager = new RailStakePositionManager(address(this), rail, staking);

        QueuedRailStrategy qRailImplementation = new QueuedRailStrategy();
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

        StakedRailStrategy implementation = new StakedRailStrategy();
        strategy = StakedRailStrategy(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(implementation),
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

        RailWithdrawer withdrawerImplementation = new RailWithdrawer();
        withdrawer = RailWithdrawer(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(withdrawerImplementation),
                        makeAddr("withdrawerProxyAdmin"),
                        abi.encodeCall(RailWithdrawer.initialize, (address(qRail), address(requests), address(rail)))
                    )
                )
            )
        );

        resolver =
            new RailWithdrawalResolver(address(this), strategy, qRail, manager, requests, withdrawer);
        stakingProcessor =
            new StakedRailStakingProcessor(address(this), strategy, manager, 1000 ether, 1000 ether, 1000 ether, 100);
        exitProcessor = new StakedRailExitProcessor(strategy, qRail, manager);

        manager.setStrategy(address(strategy));
        manager.setExitSystem(address(withdrawer));
        strategy.grantRole(strategy.PROCESSOR_ROLE(), address(stakingProcessor));
        qRail.grantRole(qRail.PROCESSOR_ROLE(), address(exitProcessor));
        qRail.grantRole(qRail.PROCESSOR_ROLE(), address(resolver));
        strategy.grantRole(strategy.PROCESSOR_MANAGER_ROLE(), address(this));
        qRail.grantRole(qRail.PROCESSOR_MANAGER_ROLE(), address(this));
        _setProcessorRules();
        manager.grantRole(manager.KEEPER_ROLE(), address(resolver));
        manager.grantRole(manager.KEEPER_ROLE(), address(exitProcessor));
        bagFactory.grantRole(bagFactory.CREATOR_ROLE(), address(requests));
        requests.setWithdrawer(address(withdrawer));
        requests.grantRole(requests.RESOLVER_ROLE(), address(resolver));
        resolver.grantRole(resolver.KEEPER_ROLE(), address(this));
        strategy.grantRole(strategy.UNPAUSER_ROLE(), address(this));
        strategy.unpause();
    }

    function testMintQueuedRailRejectsDirectCalls() external {
        vm.expectRevert(QueuedRailStrategy.OnlyProcessorSelfCall.selector);
        vm.prank(user);
        qRail.mintQueuedRail(user, 1000 ether);

        vm.expectRevert(QueuedRailStrategy.OnlyProcessorSelfCall.selector);
        vm.prank(address(exitProcessor));
        qRail.mintQueuedRail(user, 1000 ether);
        assertEq(qRail.totalSupply(), 0);
    }

    function testMintQueuedRailRejectsUnauthorizedProcessorCalls() external {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(qRail);
        data[0] = abi.encodeCall(QueuedRailStrategy.mintQueuedRail, (user, 1000 ether));

        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", user, qRail.PROCESSOR_ROLE())
        );
        vm.prank(user);
        qRail.processor(targets, values, data);
        assertEq(qRail.totalSupply(), 0);
    }

    function testDepositAndChunkedStakingAccounting() external {
        _deposit(user, 5000 ether);

        uint256 operations = stakingProcessor.rebalanceStaking(10);

        assertEq(operations, 4);
        assertEq(rail.balanceOf(address(strategy)), 1000 ether);
        assertEq(manager.activePrincipal(), 4000 ether);
        assertEq(manager.queuedPrincipal(), 0);
        assertEq(strategy.totalBaseAssets(), 5000 ether);
        assertEq(strategy.maxWithdraw(user), 0);
        assertEq(strategy.maxRedeem(user), 0);
    }

    function testQueuedRailUsesExistingWithdrawalRequestLifecycle() external {
        _deposit(user, 5000 ether);
        stakingProcessor.rebalanceStaking(10);

        vm.startPrank(user);
        strategy.approve(address(exitProcessor), 1500 ether);
        exitProcessor.exitToQueuedRail(1500 ether, user, 2);
        qRail.approve(address(requests), 1500 ether);
        uint256 requestId = requests.requestWithdrawal(1500 ether, user, "");
        vm.stopPrank();

        assertEq(qRail.balanceOf(address(requests)), 1500 ether);
        assertEq(qRail.balanceOf(address(strategy)), 500 ether);
        assertEq(qRail.convertToAssets(1500 ether), 1500 ether);
        assertEq(manager.activePrincipal(), 2000 ether);
        assertEq(manager.queuedPrincipal(), 2000 ether);
        assertEq(resolver.unstakingDeficit(), 0);
        assertEq(resolver.rebalanceExits(2), 0);

        uint256[] memory stakeIds = manager.queuedStakeIdsList();
        vm.warp(block.timestamp + 30 days + 1);
        resolver.claimMaturedPositions(stakeIds);
        assertEq(rail.balanceOf(address(qRail)), 2000 ether);

        resolver.resolveRequests(1);
        WithdrawalRequest.Request memory request = requests.requests(requestId);
        assertEq(request.amountLocked, 0);
        assertEq(rail.balanceOf(request.bag), 1500 ether);
        assertEq(qRail.balanceOf(address(requests)), 0);
        assertEq(qRail.balanceOf(address(strategy)), 500 ether);

        address[] memory assets = new address[](1);
        assets[0] = address(rail);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1500 ether;

        vm.prank(user);
        IBag(request.bag).claim(assets, payable(user), amounts);
        assertEq(rail.balanceOf(user), 1500 ether);
    }

    function _deposit(address account, uint256 amount) internal {
        rail.mint(account, amount);
        vm.startPrank(account);
        rail.approve(address(strategy), amount);
        strategy.deposit(amount, account);
        vm.stopPrank();
    }

    function _setProcessorRules() internal {
        IVault.FunctionRule memory rule = _emptyRule();
        strategy.setProcessorRule(address(rail), IERC20.transfer.selector, rule);
        strategy.setProcessorRule(address(manager), RailStakePositionManager.createPosition.selector, rule);
        qRail.setProcessorRule(address(qRail), QueuedRailStrategy.mintQueuedRail.selector, rule);
    }

    function _emptyRule() internal pure returns (IVault.FunctionRule memory rule) {
        rule.isActive = true;
        rule.paramRules = new IVault.ParamRule[](0);
        rule.validator = IValidator(address(0));
    }
}
