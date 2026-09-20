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
import {BaseWithdrawer} from "@yieldnest-vault-withdrawals/withdrawers/BaseWithdrawer.sol";
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
    BaseWithdrawer withdrawer;
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
            new StakedRailStakingProcessor(address(this), strategy, manager, 1000 ether);
        exitProcessor = new StakedRailExitProcessor(strategy, qRail, manager);

        manager.grantRole(manager.CREATOR_ROLE(), address(strategy));
        qRail.setStakedRail(address(strategy));
        strategy.grantRole(strategy.PROCESSOR_ROLE(), address(stakingProcessor));
        strategy.grantRole(strategy.PROCESSOR_ROLE(), address(exitProcessor));
        strategy.grantRole(strategy.PROCESSOR_MANAGER_ROLE(), address(this));
        qRail.grantRole(qRail.PROCESSOR_ROLE(), address(resolver));
        qRail.grantRole(qRail.PROCESSOR_MANAGER_ROLE(), address(this));
        _setProcessorRules();
        manager.grantRole(manager.CLAIMER_ROLE(), address(qRail));
        manager.grantRole(manager.QUEUER_ROLE(), address(strategy));
        bagFactory.grantRole(bagFactory.CREATOR_ROLE(), address(requests));
        requests.setWithdrawer(address(withdrawer));
        requests.grantRole(requests.RESOLVER_ROLE(), address(resolver));
        resolver.grantRole(resolver.KEEPER_ROLE(), address(this));
        strategy.grantRole(strategy.UNPAUSER_ROLE(), address(this));
        strategy.unpause();
    }

    function testMintQueuedRailRejectsDirectCalls() external {
        vm.expectRevert(QueuedRailStrategy.OnlyStakedRail.selector);
        vm.prank(user);
        qRail.mintQueuedRail(user, 1000 ether);

        vm.expectRevert(QueuedRailStrategy.OnlyStakedRail.selector);
        vm.prank(address(exitProcessor));
        qRail.mintQueuedRail(user, 1000 ether);
        assertEq(qRail.totalSupply(), 0);
    }

    function testQueuePositionRejectsDirectCalls() external {
        vm.expectRevert(StakedRailStrategy.OnlyProcessorSelfCall.selector);
        vm.prank(address(exitProcessor));
        strategy.queuePosition(0);

        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", address(exitProcessor), manager.QUEUER_ROLE()
        ));
        vm.prank(address(exitProcessor));
        manager.queuePosition(0);
    }

    function testQueuePositionAtomicallyMintsBacking() external {
        _deposit(user, 1000 ether);
        stakingProcessor.rebalanceStaking(1);
        _queueThroughStrategy(0);

        assertEq(manager.activePrincipal(), 0);
        assertEq(manager.queuedPrincipal(), 1000 ether);
        assertEq(qRail.totalSupply(), 1000 ether);
        assertEq(qRail.balanceOf(address(strategy)), 1000 ether);
        assertEq(strategy.totalBaseAssets(), 1000 ether);
    }

    function testQueuePositionRollsBackWhenMintFails() external {
        _deposit(user, 1000 ether);
        stakingProcessor.rebalanceStaking(1);
        vm.mockCallRevert(
            address(qRail),
            abi.encodeCall(QueuedRailStrategy.mintQueuedRail, (address(strategy), 1000 ether)),
            abi.encodeWithSignature("MintFailed()")
        );
        vm.expectRevert();
        _queueThroughStrategy(0);

        (,,, uint256 locktime,) = staking.stakes(address(manager), 0);
        assertEq(locktime, 0);
        assertEq(manager.activePrincipal(), 1000 ether);
        assertEq(manager.queuedPrincipal(), 0);
        assertEq(manager.activePositionCount(), 1);
        assertEq(qRail.totalSupply(), 0);
    }

    function _queueThroughStrategy(uint256 stakeId) internal {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(strategy);
        data[0] = abi.encodeCall(StakedRailStrategy.queuePosition, (stakeId));
        vm.prank(address(exitProcessor));
        strategy.processor(targets, values, data);
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

    function testManagerQueueAndClaimRolesAreSeparate() external {
        _deposit(user, 1000 ether);
        stakingProcessor.rebalanceStaking(1);

        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", address(resolver), manager.QUEUER_ROLE()
        ));
        vm.prank(address(resolver));
        manager.queuePosition(0);

        vm.prank(address(strategy));
        manager.queuePosition(0);
        vm.warp(block.timestamp + 30 days + 1);

        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", address(exitProcessor), manager.CLAIMER_ROLE()
        ));
        vm.prank(address(exitProcessor));
        manager.claimPosition(0, address(qRail));

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", address(exitProcessor), manager.CLAIMER_ROLE()
        ));
        vm.prank(address(exitProcessor));
        manager.claimMaturedPositions(ids, address(qRail));

        manager.grantRole(manager.KEEPER_ROLE(), user);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", user, manager.QUEUER_ROLE()
        ));
        vm.prank(user);
        manager.queuePosition(0);

        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", user, manager.CLAIMER_ROLE()
        ));
        vm.prank(user);
        manager.claimPosition(0, user);

        assertEq(resolver.claimMaturedPositions(ids), 1000 ether);
    }

    function testClaimRulesRestrictReceiverToQueuedRail() external {
        _deposit(user, 1000 ether);
        stakingProcessor.rebalanceStaking(1);
        _queueThroughStrategy(0);
        vm.warp(block.timestamp + 30 days + 1);

        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", address(resolver), manager.CLAIMER_ROLE()
        ));
        vm.prank(address(resolver));
        manager.claimPosition(0, user);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(manager);
        data[0] = abi.encodeCall(RailStakePositionManager.claimPosition, (0, user));
        vm.expectRevert(abi.encodeWithSignature("AddressNotInAllowlist(address)", user));
        vm.prank(address(resolver));
        qRail.processor(targets, values, data);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        data[0] = abi.encodeCall(RailStakePositionManager.claimMaturedPositions, (ids, user));
        vm.expectRevert(abi.encodeWithSignature("AddressNotInAllowlist(address)", user));
        vm.prank(address(resolver));
        qRail.processor(targets, values, data);
        assertEq(manager.queuedPrincipal(), 1000 ether);
        assertEq(rail.balanceOf(user), 0);

        data[0] = abi.encodeCall(RailStakePositionManager.claimPosition, (0, address(qRail)));
        vm.prank(address(resolver));
        qRail.processor(targets, values, data);
        assertEq(manager.queuedPrincipal(), 0);
        assertEq(rail.balanceOf(address(qRail)), 1000 ether);
    }

    function testCreatorRoleCanBeGrantedAndRevoked() external {
        bytes32 role = manager.CREATOR_ROLE();
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", user, role));
        vm.prank(user);
        manager.createPosition(1000 ether);

        manager.grantRole(role, user);
        rail.mint(address(manager), 1000 ether);
        vm.prank(user);
        manager.createPosition(1000 ether);
        assertEq(manager.activePrincipal(), 1000 ether);

        manager.revokeRole(role, user);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", user, role));
        vm.prank(user);
        manager.createPosition(1000 ether);
    }

    function testQueuedRailMinterCannotBeReplaced() external {
        assertEq(qRail.stakedRail(), address(strategy));
        vm.expectRevert(QueuedRailStrategy.StakedRailAlreadySet.selector);
        qRail.setStakedRail(user);
        vm.expectRevert(QueuedRailStrategy.InvalidStakedRail.selector);
        qRail.setStakedRail(address(0));
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", user, qRail.DEFAULT_ADMIN_ROLE()
        ));
        vm.prank(user);
        qRail.setStakedRail(user);
    }

    function testDepositAndChunkedStakingAccounting() external {
        _deposit(user, 5000 ether);

        uint256 operations = stakingProcessor.rebalanceStaking(10);

        assertEq(operations, 5);
        assertEq(rail.balanceOf(address(strategy)), 0);
        assertEq(manager.activePrincipal(), 5000 ether);
        assertEq(manager.queuedPrincipal(), 0);
        assertEq(strategy.totalBaseAssets(), 5000 ether);
        assertEq(strategy.maxWithdraw(user), 0);
        assertEq(strategy.maxRedeem(user), 0);
    }

    function testExitsWalkHeadsWithoutReadingFullList() external {
        _deposit(user, 5000 ether);
        stakingProcessor.rebalanceStaking(5);
        vm.mockCallRevert(
            address(manager), abi.encodeCall(RailStakePositionManager.activeStakeIdsList, ()), "no eager list reads"
        );
        vm.startPrank(user);
        strategy.approve(address(exitProcessor), 3000 ether);
        exitProcessor.exitToQueuedRail(1000 ether, user, 1);
        assertEq(manager.activeStakeHead(), 1);
        exitProcessor.exitToQueuedRail(2000 ether, user, 2);
        vm.stopPrank();
        assertEq(manager.activeStakeHead(), 3);
        assertEq(manager.activeStakeTail(), 4);
        assertEq(manager.activePositionCount(), 2);
        assertEq(manager.activePrincipal(), 2000 ether);
        assertEq(manager.queuedPrincipal(), 3000 ether);
        assertEq(qRail.balanceOf(user), 3000 ether);
        vm.clearMockedCalls();
        uint256[] memory ids = manager.activeStakeIdsList();
        assertEq(ids[0], 3);
        assertEq(ids[1], 4);
    }

    function testExitPositionLimitRollsBackListAndMinting() external {
        _deposit(user, 3000 ether);
        stakingProcessor.rebalanceStaking(3);
        vm.startPrank(user);
        strategy.approve(address(exitProcessor), 2000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(StakedRailExitProcessor.InsufficientQueuedRail.selector, 2000 ether, 1000 ether)
        );
        exitProcessor.exitToQueuedRail(2000 ether, user, 1);
        vm.stopPrank();
        assertEq(manager.activeStakeHead(), 0);
        assertEq(manager.activeStakeTail(), 2);
        assertEq(manager.nextActiveStakeId(0), 1);
        assertEq(manager.nextActiveStakeId(1), 2);
        assertEq(manager.activePositionCount(), 3);
        assertEq(manager.activePrincipal(), 3000 ether);
        assertEq(manager.queuedPrincipal(), 0);
        assertEq(qRail.totalSupply(), 0);
        assertEq(strategy.balanceOf(user), 3000 ether);
    }

    function testStakingLeavesRemainderAndHonorsOperationLimit() external {
        _deposit(user, 2500 ether);
        vm.prank(user);
        assertEq(stakingProcessor.rebalanceStaking(1), 1);
        assertEq(manager.activePrincipal(), 1000 ether);
        assertEq(rail.balanceOf(address(strategy)), 1500 ether);

        assertEq(stakingProcessor.rebalanceStaking(10), 1);
        assertEq(stakingProcessor.rebalanceStaking(10), 0);
        assertEq(manager.activePrincipal(), 2000 ether);
        assertEq(rail.balanceOf(address(strategy)), 500 ether);
        uint256[] memory ids = manager.activeStakeIdsList();
        for (uint256 i = 0; i < ids.length; i++) {
            (, uint256 principal,,,) = staking.stakes(address(manager), ids[i]);
            assertEq(principal, 1000 ether);
        }
    }

    function testChunkSizeChangeAppliesToNewStakes() external {
        _deposit(user, 5500 ether);
        assertEq(stakingProcessor.rebalanceStaking(1), 1);
        stakingProcessor.setStakeChunkSize(2000 ether);
        assertEq(stakingProcessor.rebalanceStaking(10), 2);
        uint256[] memory ids = manager.activeStakeIdsList();
        for (uint256 i = 0; i < ids.length; i++) {
            (, uint256 principal,,,) = staking.stakes(address(manager), ids[i]);
            assertEq(principal, i == 0 ? 1000 ether : 2000 ether);
        }
        assertEq(rail.balanceOf(address(strategy)), 500 ether);
    }

    function testChunkSizeRequiresConfigRoleAndNonzeroValue() external {
        bytes32 role = stakingProcessor.CONFIG_MANAGER_ROLE();
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", user, role));
        vm.prank(user);
        stakingProcessor.setStakeChunkSize(2000 ether);

        vm.expectRevert(StakedRailStakingProcessor.InvalidStakeChunkSize.selector);
        stakingProcessor.setStakeChunkSize(0);

        vm.expectRevert(StakedRailStakingProcessor.InvalidStakeChunkSize.selector);
        new StakedRailStakingProcessor(address(this), strategy, manager, 0);
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
        assertEq(manager.activePrincipal(), 3000 ether);
        assertEq(manager.queuedPrincipal(), 2000 ether);

        uint256[] memory stakeIds = new uint256[](2);
        stakeIds[0] = 0;
        stakeIds[1] = 1;
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
