// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Bag} from "@yieldnest-vault-withdrawals/Bag.sol";
import {BeaconProxyFactory} from "@yieldnest-vault-withdrawals/BeaconProxyFactory.sol";
import {WithdrawalRequest} from "@yieldnest-vault-withdrawals/WithdrawalRequest.sol";
import {IBag} from "@yieldnest-vault-withdrawals/interface/IBag.sol";
import {MinAmountRequestPolicy} from "@yieldnest-vault-withdrawals/policies/MinAmountRequestPolicy.sol";

import {QueuedRailStrategy} from "../../src/QueuedRailStrategy.sol";
import {StakedRailStrategy} from "../../src/StakedRailStrategy.sol";
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

    function setUp() external {
        rail = new MockERC20("RAIL", "RAIL", 18);
        staking = new MockRailgunStaking(rail);

        QueuedRailStrategy qRailImplementation = new QueuedRailStrategy();
        qRail = QueuedRailStrategy(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(qRailImplementation),
                        makeAddr("qRailProxyAdmin"),
                        abi.encodeCall(QueuedRailStrategy.initialize, (address(this), address(rail)))
                    )
                )
            )
        );

        manager = new RailStakePositionManager(address(this), rail, staking);

        StakedRailStrategy implementation = new StakedRailStrategy();
        strategy = StakedRailStrategy(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(implementation),
                        makeAddr("stRailProxyAdmin"),
                        abi.encodeCall(
                            StakedRailStrategy.initialize,
                            (address(this), address(rail), manager, qRail, 1000 ether, 1000 ether, 1000 ether, 100)
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

        resolver = new RailWithdrawalResolver(address(this), strategy, manager, requests, withdrawer);

        manager.setStrategy(address(strategy));
        manager.setExitSystem(address(withdrawer));
        qRail.grantRole(qRail.MINTER_ROLE(), address(strategy));
        qRail.grantRole(qRail.BURNER_ROLE(), address(withdrawer));
        manager.grantRole(manager.KEEPER_ROLE(), address(resolver));
        bagFactory.grantRole(bagFactory.CREATOR_ROLE(), address(requests));
        requests.setWithdrawer(address(withdrawer));
        requests.grantRole(requests.RESOLVER_ROLE(), address(resolver));
        resolver.grantRole(resolver.KEEPER_ROLE(), address(this));
        strategy.grantRole(strategy.KEEPER_ROLE(), address(this));
        strategy.grantRole(strategy.UNPAUSER_ROLE(), address(this));
        strategy.unpause();
    }

    function testDepositAndChunkedStakingAccounting() external {
        _deposit(user, 5000 ether);

        uint256 operations = strategy.rebalanceStaking(10);

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
        strategy.rebalanceStaking(10);

        vm.startPrank(user);
        strategy.exitToQueuedRail(1500 ether, user);
        qRail.approve(address(requests), 1500 ether);
        uint256 requestId = requests.requestWithdrawal(1500 ether, user, "");
        vm.stopPrank();

        assertEq(qRail.balanceOf(address(requests)), 1500 ether);
        assertEq(qRail.convertToAssets(1500 ether), 1500 ether);

        resolver.rebalanceExits(2);
        assertEq(manager.activePrincipal(), 2000 ether);
        assertEq(manager.queuedPrincipal(), 2000 ether);

        uint256[] memory stakeIds = manager.queuedStakeIdsList();
        vm.warp(block.timestamp + 30 days + 1);
        resolver.claimMaturedPositions(stakeIds);
        assertEq(rail.balanceOf(address(withdrawer)), 2000 ether);

        resolver.resolveRequests(1);
        WithdrawalRequest.Request memory request = requests.requests(requestId);
        assertEq(request.amountLocked, 0);
        assertEq(rail.balanceOf(request.bag), 1500 ether);
        assertEq(qRail.balanceOf(address(requests)), 0);

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
}
