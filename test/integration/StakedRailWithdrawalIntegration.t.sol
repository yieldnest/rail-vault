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
import {IRailgunStaking} from "../../src/railgun/IRailgunStaking.sol";
import {RailStakePositionManager} from "../../src/railgun/RailStakePositionManager.sol";
import {BaseWithdrawer} from "@yieldnest-vault-withdrawals/withdrawers/BaseWithdrawer.sol";
import {RailWithdrawalResolver} from "../../src/withdrawals/RailWithdrawalResolver.sol";

contract StakedRailWithdrawalIntegrationTest is Test {
    address internal constant RAILGUN_STAKING = 0xEE6A649Aa3766bD117e12C161726b693A1B2Ee20;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bool internal forkAvailable;
    IERC20 internal rail;
    IRailgunStaking internal staking;
    QueuedRailStrategy internal qRail;
    RailStakePositionManager internal manager;
    StakedRailStrategy internal strategy;
    BeaconProxyFactory internal bagFactory;
    WithdrawalRequest internal requests;
    BaseWithdrawer internal withdrawer;
    RailWithdrawalResolver internal resolver;
    StakedRailStakingProcessor internal stakingProcessor;
    StakedRailExitProcessor internal exitProcessor;

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

        StakedRailStrategy strategyImplementation = new StakedRailStrategy();
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
            new RailWithdrawalResolver(address(this), qRail, manager, requests);
        stakingProcessor =
            new StakedRailStakingProcessor(address(this), strategy, manager, 1000 ether, 1000 ether, 1000 ether, 100);
        exitProcessor = new StakedRailExitProcessor(strategy, qRail, manager);

        manager.setStrategy(address(strategy));
        manager.setExitSystem(address(withdrawer));
        strategy.grantRole(strategy.PROCESSOR_ROLE(), address(stakingProcessor));
        qRail.grantRole(qRail.PROCESSOR_ROLE(), address(exitProcessor));
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

    function testFullStakedRailToRequestNftToRailClaimFlow() external {
        vm.skip(!forkAvailable, "ETH_MAINNET_RPC_URL is not set");

        assertEq(address(staking), RAILGUN_STAKING);
        assertEq(staking.STAKE_LOCKTIME(), 30 days);
        assertEq(staking.stakingToken(), address(rail));

        _deposit(alice, 5000 ether);

        assertEq(stakingProcessor.rebalanceStaking(10), 4);
        assertEq(manager.activePrincipal(), 4000 ether);
        assertEq(rail.balanceOf(address(strategy)), 1000 ether);

        vm.startPrank(alice);
        strategy.approve(address(exitProcessor), 1500 ether);
        uint256 qRailAmount = exitProcessor.exitToQueuedRail(1500 ether, alice, 2);
        qRail.approve(address(requests), qRailAmount);
        uint256 requestId = requests.requestWithdrawal(qRailAmount, alice, "integration");
        requests.transferFrom(alice, bob, requestId);
        vm.stopPrank();

        assertEq(qRailAmount, 1500 ether);
        assertEq(strategy.balanceOf(alice), 3500 ether);
        assertEq(qRail.balanceOf(address(requests)), 1500 ether);
        assertEq(qRail.balanceOf(address(strategy)), 500 ether);
        assertEq(requests.ownerOf(requestId), bob);
        assertEq(manager.activePrincipal(), 2000 ether);
        assertEq(manager.queuedPrincipal(), 2000 ether);

        uint256[] memory stakeIds = manager.queuedStakeIdsList();
        vm.warp(block.timestamp + 30 days + 1);
        assertEq(resolver.claimMaturedPositions(stakeIds), 2000 ether);
        assertEq(rail.balanceOf(address(qRail)), 2000 ether);

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

    function _deposit(address account, uint256 amount) internal {
        deal(address(rail), account, amount);
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
