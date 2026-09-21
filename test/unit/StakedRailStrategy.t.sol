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
import {StakedRailProcessor} from "../../src/processors/StakedRailProcessor.sol";
import {QueuedRailProcessor} from "../../src/processors/QueuedRailProcessor.sol";
import {RailStakePositionManager} from "../../src/railgun/RailStakePositionManager.sol";
import {IRailgunStaking} from "../../src/railgun/IRailgunStaking.sol";
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
    QueuedRailProcessor internal queuedRailProcessor;
    StakedRailProcessor processor;

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
            new RailWithdrawalResolver(address(this), qRail, requests);
        processor =
            new StakedRailProcessor(address(this), strategy, 1000 ether);

        queuedRailProcessor = new QueuedRailProcessor(address(this), qRail);
        queuedRailProcessor.grantRole(queuedRailProcessor.KEEPER_ROLE(), address(this));

        manager.grantRole(manager.CREATOR_ROLE(), address(strategy));
        qRail.setStakedRail(address(strategy));
        strategy.grantRole(strategy.PROCESSOR_ROLE(), address(processor));
        strategy.grantRole(strategy.PROCESSOR_MANAGER_ROLE(), address(this));
        qRail.grantRole(qRail.PROCESSOR_ROLE(), address(queuedRailProcessor));
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
        vm.prank(address(processor));
        qRail.mintQueuedRail(user, 1000 ether);
        assertEq(qRail.totalSupply(), 0);
    }

    function testQueuePositionRejectsDirectCalls() external {
        vm.expectRevert(StakedRailStrategy.OnlyProcessorSelfCall.selector);
        vm.prank(address(processor));
        strategy.queuePosition();

        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", address(processor), manager.QUEUER_ROLE()
        ));
        vm.prank(address(processor));
        manager.queuePosition();
    }

    function testQueuePositionAtomicallyMintsBacking() external {
        _deposit(user, 1000 ether);
        processor.rebalanceStaking(1);
        _queueThroughStrategy();

        assertEq(manager.activePrincipal(), 0);
        assertEq(manager.queuedPrincipal(), 1000 ether);
        assertEq(qRail.totalSupply(), 1000 ether);
        assertEq(qRail.balanceOf(address(strategy)), 1000 ether);
        assertEq(strategy.totalBaseAssets(), 1000 ether);
    }

    function testQueuePositionRollsBackWhenMintFails() external {
        _deposit(user, 1000 ether);
        processor.rebalanceStaking(1);
        vm.mockCallRevert(
            address(qRail),
            abi.encodeCall(QueuedRailStrategy.mintQueuedRail, (address(strategy), 1000 ether)),
            abi.encodeWithSignature("MintFailed()")
        );
        vm.expectRevert();
        _queueThroughStrategy();

        (,,, uint256 locktime,) = staking.stakes(address(manager), 0);
        assertEq(locktime, 0);
        assertEq(manager.activePrincipal(), 1000 ether);
        assertEq(manager.queuedPrincipal(), 0);
        assertEq(manager.activePositionCount(), 1);
        assertEq(qRail.totalSupply(), 0);
    }

    function _queueThroughStrategy() internal {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(strategy);
        data[0] = abi.encodeCall(StakedRailStrategy.queuePosition, ());
        vm.prank(address(processor));
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
        processor.rebalanceStaking(1);

        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", address(resolver), manager.QUEUER_ROLE()
        ));
        vm.prank(address(resolver));
        manager.queuePosition();

        vm.prank(address(strategy));
        manager.queuePosition();
        vm.warp(block.timestamp + 30 days + 1);

        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", address(processor), manager.CLAIMER_ROLE()
        ));
        vm.prank(address(processor));
        manager.claimPosition(0, address(qRail));

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", address(processor), manager.CLAIMER_ROLE()
        ));
        vm.prank(address(processor));
        manager.claimMaturedPositions(ids, address(qRail));

        manager.grantRole(manager.KEEPER_ROLE(), user);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", user, manager.QUEUER_ROLE()
        ));
        vm.prank(user);
        manager.queuePosition();

        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", user, manager.CLAIMER_ROLE()
        ));
        vm.prank(user);
        manager.claimPosition(0, user);

        assertEq(queuedRailProcessor.claimMaturedPositions(ids), 1000 ether);
    }

    function testClaimRulesRestrictReceiverToQueuedRail() external {
        _deposit(user, 1000 ether);
        processor.rebalanceStaking(1);
        _queueThroughStrategy();
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
        vm.prank(address(queuedRailProcessor));
        qRail.processor(targets, values, data);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        data[0] = abi.encodeCall(RailStakePositionManager.claimMaturedPositions, (ids, user));
        vm.expectRevert(abi.encodeWithSignature("AddressNotInAllowlist(address)", user));
        vm.prank(address(queuedRailProcessor));
        qRail.processor(targets, values, data);
        assertEq(manager.queuedPrincipal(), 1000 ether);
        assertEq(rail.balanceOf(user), 0);

        data[0] = abi.encodeCall(RailStakePositionManager.claimPosition, (0, address(qRail)));
        vm.prank(address(queuedRailProcessor));
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
        rail.mint(user, 1000 ether);
        vm.prank(user);
        rail.approve(address(manager), 1000 ether);
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

    function testQueuedProcessorAndResolverHaveSeparatePermissions() external {
        bytes32 processorRole = qRail.PROCESSOR_ROLE();
        bytes32 resolverRole = requests.RESOLVER_ROLE();
        assertTrue(qRail.hasRole(processorRole, address(queuedRailProcessor)));
        assertFalse(qRail.hasRole(processorRole, address(resolver)));
        assertTrue(requests.hasRole(resolverRole, address(resolver)));
        assertFalse(requests.hasRole(resolverRole, address(queuedRailProcessor)));
        assertFalse(manager.hasRole(manager.CLAIMER_ROLE(), address(queuedRailProcessor)));
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", address(resolver), processorRole
        ));
        vm.prank(address(resolver));
        qRail.processor(new address[](0), new uint256[](0), new bytes[](0));
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", address(queuedRailProcessor), resolverRole
        ));
        vm.prank(address(queuedRailProcessor));
        requests.resolveWithdrawalRequest(0, address(rail), 1);
    }

    function testQueuedProcessorRequiresKeeperAndVaultProcessorRoles() external {
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", user, queuedRailProcessor.KEEPER_ROLE()
        ));
        vm.prank(user);
        queuedRailProcessor.claimMaturedPositions(ids);
        bytes32 role = qRail.PROCESSOR_ROLE();
        qRail.revokeRole(role, address(queuedRailProcessor));
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", address(queuedRailProcessor), role
        ));
        queuedRailProcessor.claimMaturedPositions(ids);
    }

    function testProcessorsDeriveDependenciesFromVaults() external view {
        assertEq(address(processor.qRail()), address(strategy.queuedRail()));
        assertEq(address(processor.positionManager()), address(strategy.positionManager()));
        assertEq(address(queuedRailProcessor.positionManager()), address(qRail.positionManager()));
    }

    function testProcessorRoleRevocationBlocksStakingAndQueueing() external {
        _deposit(user, 2000 ether);
        processor.rebalanceStaking(1);
        bytes32 role = strategy.PROCESSOR_ROLE();
        strategy.revokeRole(role, address(processor));
        bytes memory expected = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", address(processor), role
        );
        vm.expectRevert(expected);
        processor.rebalanceStaking(1);
        vm.prank(user);
        strategy.approve(address(processor), 1000 ether);
        vm.expectRevert(expected);
        vm.prank(user);
        processor.exitToQueuedRail(1000 ether, user, 1);
        assertEq(manager.activePrincipal(), 1000 ether);
        assertEq(manager.queuedPrincipal(), 0);
        assertEq(qRail.totalSupply(), 0);
        assertEq(strategy.balanceOf(user), 2000 ether);
    }

    function testDepositAndChunkedStakingAccounting() external {
        _deposit(user, 5000 ether);

        uint256 operations = processor.rebalanceStaking(10);

        assertEq(operations, 5);
        assertEq(rail.balanceOf(address(strategy)), 0);
        assertEq(manager.activePrincipal(), 5000 ether);
        assertEq(manager.queuedPrincipal(), 0);
        assertEq(strategy.totalBaseAssets(), 5000 ether);
        assertEq(strategy.maxWithdraw(user), 0);
        assertEq(strategy.maxRedeem(user), 0);
    }

    function testExitsPopOldestWithoutReadingFullList() external {
        _deposit(user, 5000 ether);
        processor.rebalanceStaking(5);
        vm.mockCallRevert(
            address(manager), abi.encodeCall(RailStakePositionManager.activeStakeIdsList, ()), "no eager list reads"
        );
        vm.startPrank(user);
        strategy.approve(address(processor), 3000 ether);
        processor.exitToQueuedRail(1000 ether, user, 1);
        assertEq(manager.activeStakeHead(), 1);
        processor.exitToQueuedRail(2000 ether, user, 2);
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

    function testExitPositionLimitRollsBackQueueAndMinting() external {
        _deposit(user, 3000 ether);
        processor.rebalanceStaking(3);
        vm.startPrank(user);
        strategy.approve(address(processor), 2000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(StakedRailProcessor.InsufficientQueuedRail.selector, 2000 ether, 1000 ether)
        );
        processor.exitToQueuedRail(2000 ether, user, 1);
        vm.stopPrank();
        assertEq(manager.activeStakeHead(), 0);
        assertEq(manager.activeStakeTail(), 2);
        uint256[] memory ids = manager.activeStakeIdsList();
        for (uint256 i = 0; i < 3; i++) assertEq(ids[i], i);
        assertEq(manager.activePositionCount(), 3);
        assertEq(manager.activePrincipal(), 3000 ether);
        assertEq(manager.queuedPrincipal(), 0);
        assertEq(qRail.totalSupply(), 0);
        assertEq(strategy.balanceOf(user), 3000 ether);
    }

    function testStakingFailureRollsBackCallerFundingAndApproval() external {
        _deposit(user, 1000 ether);
        vm.mockCallRevert(
            address(staking), abi.encodeCall(IRailgunStaking.stake, (1000 ether)), abi.encodeWithSignature("StakeFailed()")
        );
        vm.expectRevert();
        processor.rebalanceStaking(1);
        assertEq(rail.balanceOf(address(strategy)), 1000 ether);
        assertEq(rail.balanceOf(address(manager)), 0);
        assertEq(rail.allowance(address(strategy), address(manager)), 0);
        assertEq(rail.allowance(address(manager), address(staking)), 0);
        assertEq(manager.activePositionCount(), 0);
        assertEq(manager.activePrincipal(), 0);
    }

    function testStakingLeavesRemainderAndHonorsOperationLimit() external {
        _deposit(user, 2500 ether);
        vm.prank(user);
        assertEq(processor.rebalanceStaking(1), 1);
        assertEq(manager.activePrincipal(), 1000 ether);
        assertEq(rail.balanceOf(address(strategy)), 1500 ether);

        assertEq(processor.rebalanceStaking(10), 1);
        assertEq(processor.rebalanceStaking(10), 0);
        assertEq(manager.activePrincipal(), 2000 ether);
        assertEq(rail.balanceOf(address(strategy)), 500 ether);
        assertEq(rail.allowance(address(strategy), address(manager)), 0);
        uint256[] memory ids = manager.activeStakeIdsList();
        for (uint256 i = 0; i < ids.length; i++) {
            (, uint256 principal,,,) = staking.stakes(address(manager), ids[i]);
            assertEq(principal, 1000 ether);
        }
    }

    function testChunkSizeChangeAppliesToNewStakes() external {
        _deposit(user, 5500 ether);
        assertEq(processor.rebalanceStaking(1), 1);
        processor.setStakeChunkSize(2000 ether);
        assertEq(processor.rebalanceStaking(10), 2);
        uint256[] memory ids = manager.activeStakeIdsList();
        for (uint256 i = 0; i < ids.length; i++) {
            (, uint256 principal,,,) = staking.stakes(address(manager), ids[i]);
            assertEq(principal, i == 0 ? 1000 ether : 2000 ether);
        }
        assertEq(rail.balanceOf(address(strategy)), 500 ether);
    }

    function testChunkSizeRequiresConfigRoleAndNonzeroValue() external {
        bytes32 role = processor.CONFIG_MANAGER_ROLE();
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", user, role));
        vm.prank(user);
        processor.setStakeChunkSize(2000 ether);

        vm.expectRevert(StakedRailProcessor.InvalidStakeChunkSize.selector);
        processor.setStakeChunkSize(0);

        vm.expectRevert(StakedRailProcessor.InvalidStakeChunkSize.selector);
        new StakedRailProcessor(address(this), strategy, 0);
    }

    function testQueuedRailUsesExistingWithdrawalRequestLifecycle() external {
        _deposit(user, 5000 ether);
        processor.rebalanceStaking(10);

        vm.startPrank(user);
        strategy.approve(address(processor), 1500 ether);
        processor.exitToQueuedRail(1500 ether, user, 2);
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
        queuedRailProcessor.claimMaturedPositions(stakeIds);
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

    function testFuzzResolverDonationSettlementBurnsExactShares(uint256 donation, uint256 locked) external {
        donation = bound(donation, 0, 1_000_000 ether);
        locked = bound(locked, 1, 2000 ether);
        _deposit(user, 2000 ether);
        processor.rebalanceStaking(2);
        vm.startPrank(user);
        strategy.approve(address(processor), 2000 ether);
        processor.exitToQueuedRail(2000 ether, user, 2);
        qRail.approve(address(requests), locked);
        uint256 id = requests.requestWithdrawal(locked, user, "");
        vm.stopPrank();
        rail.mint(address(qRail), donation);
        vm.warp(block.timestamp + 30 days + 1);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
        queuedRailProcessor.claimMaturedPositions(ids);
        uint256 expected = qRail.previewRedeem(locked);
        uint256 supplyBefore = qRail.totalSupply();
        assertEq(resolver.resolveRequests(1), 1);
        assertEq(requests.requests(id).amountLocked, 0);
        assertEq(qRail.totalSupply(), supplyBefore - locked);
        assertEq(rail.balanceOf(requests.requests(id).bag), expected);
        assertEq(resolver.nextRequestToResolve(), id + 1);
    }

    function _setProcessorRules() internal {
        IVault.FunctionRule memory rule = _emptyRule();
        strategy.setProcessorRule(address(rail), IERC20.approve.selector, rule);
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
