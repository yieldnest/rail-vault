// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {RailManagerDeploymentLib} from "../../script/libraries/RailDeploymentLib.sol";

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
import {RailProvider} from "../../src/core/RailProvider.sol";
import {QueuedRailSetupLib, StakedRailSetupLib} from "../../script/libraries/RailDeploymentLib.sol";
import {RailReceiptToken} from "../../src/core/RailReceiptToken.sol";
import {StakedRailStrategy} from "../../src/core/StakedRailStrategy.sol";
import {StakedRailProcessor} from "../../src/processors/StakedRailProcessor.sol";
import {QueuedRailProcessor} from "../../src/processors/QueuedRailProcessor.sol";
import {RailStakePositionManager} from "../../src/core/RailStakePositionManager.sol";
import {IRailgunStaking} from "../../src/railgun/IRailgunStaking.sol";
import {BaseWithdrawer} from "@yieldnest-vault-withdrawals/withdrawers/BaseWithdrawer.sol";
import {SingleAssetFIFOResolver} from "../../src/withdrawals/SingleAssetFIFOResolver.sol";
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
    SingleAssetFIFOResolver resolver;
    QueuedRailProcessor internal queuedRailProcessor;
    StakedRailProcessor processor;

    function setUp() external {
        rail = new MockERC20("RAIL", "RAIL", 18);
        staking = new MockRailgunStaking(rail);

        manager = RailManagerDeploymentLib.deploy(address(rail), address(staking), address(this));

        QueuedRailStrategy qRailImplementation = new QueuedRailStrategy();
        StakedRailStrategy implementation = new StakedRailStrategy();
        qRail = QueuedRailStrategy(
            payable(address(
                    new TransparentUpgradeableProxy(
                        address(qRailImplementation),
                        makeAddr("qRailProxyAdmin"),
                        abi.encodeCall(
                            QueuedRailStrategy.initialize,
                            (address(this), "Queued RAIL", "qRAIL", rail.decimals(), false, false, true, 0)
                        )
                    )
                ))
        );

        QueuedRailSetupLib.configure(qRail, address(rail), address(manager.unlockedRail()), address(this));
        strategy = StakedRailStrategy(
            payable(address(
                    new TransparentUpgradeableProxy(
                        address(implementation),
                        makeAddr("stRailProxyAdmin"),
                        abi.encodeCall(
                            StakedRailStrategy.initialize,
                            (
                                address(this),
                                "Staked RAIL",
                                "stRAIL",
                                rail.decimals(),
                                true,
                                false,
                                true,
                                0,
                                manager,
                                qRail
                            )
                        )
                    )
                ))
        );

        StakedRailSetupLib.configure(strategy, address(rail), address(this));
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
            payable(address(
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
                ))
        );

        BaseWithdrawer withdrawerImplementation = new BaseWithdrawer();
        withdrawer = BaseWithdrawer(
            payable(address(
                    new TransparentUpgradeableProxy(
                        address(withdrawerImplementation),
                        makeAddr("withdrawerProxyAdmin"),
                        abi.encodeCall(BaseWithdrawer.initialize, (address(qRail), address(requests)))
                    )
                ))
        );

        resolver = SingleAssetFIFOResolver(
            address(
                new TransparentUpgradeableProxy(
                    address(new SingleAssetFIFOResolver()),
                    address(this),
                    abi.encodeCall(SingleAssetFIFOResolver.initialize, (IERC4626(address(qRail)), requests))
                )
            )
        );
        processor = new StakedRailProcessor(address(this), strategy, 1000 ether);

        queuedRailProcessor = new QueuedRailProcessor(address(this), qRail, manager);
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

    function testWithdrawalFeeConfigurationAndRounding() external {
        assertEq(strategy.baseWithdrawalFee(), 0);
        bytes32 role = strategy.FEE_MANAGER_ROLE();
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", user, role));
        vm.prank(user);
        strategy.setBaseWithdrawalFee(10_000);
        strategy.grantRole(role, address(this));
        strategy.setBaseWithdrawalFee(10_000);
        assertEq(strategy.baseWithdrawalFee(), 10_000);
        assertEq(strategy._feeOnRaw(1, user), 1);
        assertEq(strategy._feeOnTotal(1, user), 1);
        vm.expectRevert(abi.encodeWithSelector(IVault.ExceedsMaxBasisPoints.selector, uint256(100_000_001)));
        strategy.setBaseWithdrawalFee(100_000_001);
    }

    function testWithdrawalFeeRetainedOnDirectAndProcessorRedemption() external {
        strategy.grantRole(strategy.FEE_MANAGER_ROLE(), address(this));
        strategy.setBaseWithdrawalFee(10_000);
        _deposit(user, 3000 ether);
        processor.rebalanceStaking(3);
        _queueThroughStrategy();

        uint256 gross = strategy.convertToAssets(1000 ether);
        uint256 expected = gross - strategy._feeOnTotal(gross, user);
        vm.prank(user);
        assertEq(strategy.redeemAsset(address(qRail), 1000 ether, user, user), expected);
        assertEq(qRail.balanceOf(address(strategy)), gross - expected);
        assertGt(strategy.convertToAssets(1 ether), 1 ether);

        gross = strategy.convertToAssets(1000 ether);
        expected = gross - strategy._feeOnTotal(gross, address(processor));
        vm.startPrank(user);
        strategy.approve(address(processor), 1000 ether);
        assertEq(processor.exitToQueuedRail(1000 ether, user, 2), expected);
        vm.stopPrank();
        assertGt(strategy.totalAssets(), strategy.totalSupply());
    }

    function testWithdrawalFeeChargesExtraSharesOnDirectWithdraw() external {
        strategy.grantRole(strategy.FEE_MANAGER_ROLE(), address(this));
        strategy.setBaseWithdrawalFee(10_000);
        _deposit(user, 2000 ether);
        processor.rebalanceStaking(2);
        _queueThroughStrategy();
        vm.prank(user);
        assertEq(strategy.withdrawAsset(address(qRail), 1000 ether, user, user), 1000.1 ether);
        assertEq(qRail.balanceOf(user), 1000 ether);
        assertEq(strategy.totalAssets(), 1000 ether);
        assertEq(strategy.totalSupply(), 999.9 ether);
    }

    function testProviderUsesLiveQueuedRailRate() external {
        RailProvider provider = RailProvider(strategy.provider());
        assertEq(provider.getRate(address(rail)), 1 ether);
        assertEq(provider.getRate(address(qRail)), 1 ether);

        _deposit(user, 2000 ether);
        processor.rebalanceStaking(2);
        _queueThroughStrategy();
        assertEq(strategy.totalBaseAssets(), 2000 ether);

        rail.mint(address(qRail), 500 ether);
        uint256 liveRate = qRail.previewMint(1 ether);
        assertGt(liveRate, 1 ether);
        assertEq(provider.getRate(address(qRail)), liveRate);
        assertEq(provider.getRate(address(rail)), 1 ether);
        assertEq(strategy.totalBaseAssets(), manager.activeRail().totalSupply() + 1000 * liveRate);

        // Remove the donation to verify the rate also tracks decreases in backing.
        deal(address(rail), address(qRail), 0);
        assertEq(provider.getRate(address(qRail)), 1 ether);
        assertEq(strategy.totalBaseAssets(), 2000 ether);
    }

    function testProviderRejectsUnsupportedAssets() external {
        RailProvider provider = RailProvider(strategy.provider());
        vm.expectRevert(abi.encodeWithSelector(RailProvider.UnsupportedAsset.selector, user));
        provider.getRate(user);

        RailProvider railOnlyProvider = RailProvider(qRail.provider());
        vm.expectRevert(abi.encodeWithSelector(RailProvider.UnsupportedAsset.selector, address(0)));
        railOnlyProvider.getRate(address(0));
    }

    function testApprovalRuleRestrictsSpenderToPositionManager() external {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(rail);
        data[0] = abi.encodeCall(IERC20.approve, (user, 1000 ether));

        vm.expectRevert(abi.encodeWithSignature("AddressNotInAllowlist(address)", user));
        vm.prank(address(processor));
        strategy.processor(targets, values, data);
        assertEq(rail.allowance(address(strategy), user), 0);

        data[0] = abi.encodeCall(IERC20.approve, (address(manager), 1000 ether));
        vm.prank(address(processor));
        strategy.processor(targets, values, data);
        assertEq(rail.allowance(address(strategy), address(manager)), 1000 ether);
    }

    function testReceiptsOnlyManagerCanMintAndBurn() external {
        RailReceiptToken[2] memory receipts = [manager.activeRail(), manager.unlockedRail()];
        for (uint256 i; i < receipts.length; i++) {
            assertEq(receipts[i].manager(), address(manager));
            assertEq(receipts[i].decimals(), rail.decimals());
            vm.expectRevert(RailReceiptToken.OnlyManager.selector);
            receipts[i].mint(user, 1000 ether);
            vm.expectRevert(RailReceiptToken.OnlyManager.selector);
            receipts[i].burn(user, 1000 ether);
        }
    }

    function testQueuePositionRejectsDirectCalls() external {
        vm.expectRevert(StakedRailStrategy.OnlyProcessorSelfCall.selector);
        vm.prank(address(processor));
        strategy.queuePosition();

        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", address(processor), manager.QUEUER_ROLE()
            )
        );
        vm.prank(address(processor));
        manager.queuePosition();
    }

    function testQueuePositionAtomicallyMintsBacking() external {
        _deposit(user, 1000 ether);
        processor.rebalanceStaking(1);
        _queueThroughStrategy();

        assertEq(manager.activeRail().totalSupply(), 0);
        assertEq(manager.unlockedRail().totalSupply(), 1000 ether);
        assertEq(qRail.totalSupply(), 1000 ether);
        assertEq(qRail.balanceOf(address(strategy)), 1000 ether);
        assertEq(strategy.totalBaseAssets(), 1000 ether);
        assertEq(manager.activeRail().balanceOf(address(strategy)), 0);
        assertEq(manager.unlockedRail().balanceOf(address(strategy)), 0);
        assertEq(manager.unlockedRail().balanceOf(address(qRail)), 1000 ether);
    }

    function testFuzzQueueAfterDonationDoesNotDiluteExistingHolders(uint256 donation) external {
        donation = bound(donation, 1, 1_000_000 ether);
        _deposit(user, 3000 ether);
        processor.rebalanceStaking(3);
        vm.startPrank(user);
        strategy.approve(address(processor), 1000 ether);
        processor.exitToQueuedRail(1000 ether, user, 1);
        vm.stopPrank();

        rail.mint(address(qRail), donation);
        uint256 holderAssets = qRail.convertToAssets(qRail.balanceOf(user));
        uint256 expectedShares = qRail.previewDepositAsset(address(manager.unlockedRail()), 1000 ether);
        uint256 supplyBefore = qRail.totalSupply();
        _queueThroughStrategy();

        assertEq(qRail.totalSupply() - supplyBefore, expectedShares);
        assertLt(expectedShares, 1000 ether);
        assertGe(qRail.convertToAssets(qRail.balanceOf(user)), holderAssets);
        assertEq(qRail.totalAssets(), 2000 ether + donation);
        assertEq(manager.unlockedRail().balanceOf(address(qRail)), 2000 ether);
        assertEq(manager.activeRail().balanceOf(address(strategy)), 1000 ether);
        assertEq(manager.unlockedRail().balanceOf(address(strategy)), 0);
    }

    function testManagerReceiptsOutsideVaultDoNotInflateVaultAssets() external {
        manager.grantRole(manager.CREATOR_ROLE(), user);
        manager.grantRole(manager.QUEUER_ROLE(), user);
        rail.mint(user, 1000 ether);
        vm.startPrank(user);
        rail.approve(address(manager), 1000 ether);
        manager.createPosition(1000 ether);
        manager.queuePosition();
        vm.stopPrank();
        assertEq(manager.unlockedRail().balanceOf(user), 1000 ether);
        assertEq(strategy.totalAssets(), 0);
        assertEq(qRail.totalAssets(), 0);

        IERC20 unlockedRail = IERC20(address(manager.unlockedRail()));
        vm.prank(user);
        assertTrue(unlockedRail.transfer(address(strategy), 1000 ether));
        assertEq(strategy.totalAssets(), 0);
        vm.startPrank(address(strategy));
        unlockedRail.approve(address(qRail), 1000 ether);
        assertEq(qRail.depositAsset(address(unlockedRail), 1000 ether, address(strategy)), 1000 ether);
        vm.stopPrank();
        assertEq(qRail.totalAssets(), 1000 ether);
        assertEq(strategy.totalAssets(), 1000 ether);
    }

    function testClaimReplacesUnlockedReceiptsWithoutChangingVaultAssets() external {
        _deposit(user, 1000 ether);
        processor.rebalanceStaking(1);
        _queueThroughStrategy();
        rail.mint(address(qRail), 500 ether);
        uint256 assetsBefore = qRail.totalAssets();
        uint256 strategyAssetsBefore = strategy.totalAssets();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.warp(block.timestamp + 30 days + 1);
        queuedRailProcessor.claimMaturedPositions(ids);
        assertEq(manager.unlockedRail().totalSupply(), 0);
        assertEq(manager.unlockedRail().balanceOf(address(qRail)), 0);
        assertEq(rail.balanceOf(address(qRail)), assetsBefore);
        assertEq(qRail.totalAssets(), assetsBefore);
        assertEq(strategy.totalAssets(), strategyAssetsBefore);
    }

    function testQueuePositionRollsBackWhenDepositFails() external {
        _deposit(user, 1000 ether);
        processor.rebalanceStaking(1);
        vm.mockCallRevert(
            address(qRail),
            abi.encodeWithSignature(
                "depositAsset(address,uint256,address)", address(manager.unlockedRail()), 1000 ether, address(strategy)
            ),
            abi.encodeWithSignature("DepositFailed()")
        );
        vm.expectRevert();
        _queueThroughStrategy();

        (,,, uint256 locktime,) = staking.stakes(address(manager), 0);
        assertEq(locktime, 0);
        assertEq(manager.activeRail().totalSupply(), 1000 ether);
        assertEq(manager.unlockedRail().totalSupply(), 0);
        assertEq(manager.activePositionCount(), 1);
        assertEq(qRail.totalSupply(), 0);
    }

    function testQueueRollsBackIfDonationMakesDepositRoundToZeroShares() external {
        _deposit(user, 1000 ether);
        processor.rebalanceStaking(1);
        rail.mint(address(qRail), 1000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.ProcessFailed.selector,
                abi.encodeCall(StakedRailStrategy.queuePosition, ()),
                abi.encodeWithSelector(StakedRailStrategy.ZeroQueuedShares.selector)
            )
        );
        _queueThroughStrategy();
        assertEq(manager.activeRail().balanceOf(address(strategy)), 1000 ether);
        assertEq(manager.unlockedRail().totalSupply(), 0);
        assertEq(qRail.totalSupply(), 0);
        assertEq(strategy.totalAssets(), 1000 ether);
        (,,, uint256 locktime,) = staking.stakes(address(manager), 0);
        assertEq(locktime, 0);
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

    function testQueuedRailRejectsUnauthorizedProcessorCalls() external {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(manager);
        data[0] = abi.encodeCall(RailStakePositionManager.claimPosition, (0, user));

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

        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", address(resolver), manager.QUEUER_ROLE()
            )
        );
        vm.prank(address(resolver));
        manager.queuePosition();

        _queueThroughStrategy();
        vm.warp(block.timestamp + 30 days + 1);

        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", address(processor), manager.CLAIMER_ROLE()
            )
        );
        vm.prank(address(processor));
        manager.claimPosition(0, address(qRail));

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", address(processor), manager.CLAIMER_ROLE()
            )
        );
        vm.prank(address(processor));
        manager.claimMaturedPositions(ids, address(qRail));

        manager.grantRole(manager.TOKEN_WITHDRAWER_ROLE(), user);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", user, manager.QUEUER_ROLE())
        );
        vm.prank(user);
        manager.queuePosition();

        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", user, manager.CLAIMER_ROLE())
        );
        vm.prank(user);
        manager.claimPosition(0, user);

        assertEq(queuedRailProcessor.claimMaturedPositions(ids), 1000 ether);
    }

    function testClaimRulesRestrictReceiverToQueuedRail() external {
        _deposit(user, 1000 ether);
        processor.rebalanceStaking(1);
        _queueThroughStrategy();
        vm.warp(block.timestamp + 30 days + 1);

        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", address(resolver), manager.CLAIMER_ROLE()
            )
        );
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
        assertEq(manager.unlockedRail().totalSupply(), 1000 ether);
        assertEq(rail.balanceOf(user), 0);

        data[0] = abi.encodeCall(RailStakePositionManager.claimPosition, (0, address(qRail)));
        vm.prank(address(queuedRailProcessor));
        qRail.processor(targets, values, data);
        assertEq(manager.unlockedRail().totalSupply(), 0);
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
        assertEq(manager.activeRail().totalSupply(), 1000 ether);

        manager.revokeRole(role, user);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", user, role));
        vm.prank(user);
        manager.createPosition(1000 ether);
    }

    function testStakedRailInitializerForwardsAllParameters() external {
        StakedRailStrategy implementation = new StakedRailStrategy();
        StakedRailStrategy configured = StakedRailStrategy(
            payable(address(
                    new TransparentUpgradeableProxy(
                        address(implementation),
                        address(this),
                        abi.encodeCall(
                            StakedRailStrategy.initialize,
                            (user, "Custom Stake", "CUSTOM", 6, false, true, false, 1, manager, qRail)
                        )
                    )
                ))
        );
        assertTrue(configured.hasRole(configured.DEFAULT_ADMIN_ROLE(), user));
        assertFalse(configured.hasRole(configured.DEFAULT_ADMIN_ROLE(), address(this)));
        assertEq(configured.name(), "Custom Stake");
        assertEq(configured.symbol(), "CUSTOM");
        assertEq(configured.decimals(), 6);
        assertFalse(configured.paused());
        assertTrue(configured.countNativeAsset());
        assertFalse(configured.alwaysComputeTotalAssets());
        assertEq(configured.defaultAssetIndex(), 1);
        assertEq(address(configured.positionManager()), address(manager));
        assertEq(address(configured.queuedRail()), address(qRail));
        assertEq(configured.getAssets().length, 0);
    }

    function testStakedRailCannotBeReinitialized() external {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        strategy.initialize(user, "Custom Stake", "CUSTOM", 6, false, true, false, 1, manager, qRail);
    }

    function testQueuedRailCannotBeReinitialized() external {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        qRail.initialize(address(this), "Queued RAIL", "qRAIL", 18, false, false, true, 0);
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        vm.prank(user);
        qRail.initialize(user, "Queued RAIL", "qRAIL", 18, false, false, true, 0);
        assertTrue(qRail.getAsset(address(manager.unlockedRail())).active);
    }

    function testQueuedRailInitializerForwardsAllParameters() external {
        QueuedRailStrategy implementation = new QueuedRailStrategy();
        QueuedRailStrategy configured = QueuedRailStrategy(
            payable(address(
                    new TransparentUpgradeableProxy(
                        address(implementation),
                        address(this),
                        abi.encodeCall(
                            QueuedRailStrategy.initialize, (user, "Custom Queue", "CUSTOM", 6, true, true, false, 1)
                        )
                    )
                ))
        );
        assertTrue(configured.hasRole(configured.DEFAULT_ADMIN_ROLE(), user));
        assertFalse(configured.hasRole(configured.DEFAULT_ADMIN_ROLE(), address(this)));
        assertEq(configured.name(), "Custom Queue");
        assertEq(configured.symbol(), "CUSTOM");
        assertEq(configured.decimals(), 6);
        assertTrue(configured.paused());
        assertTrue(configured.countNativeAsset());
        assertFalse(configured.alwaysComputeTotalAssets());
        assertEq(configured.defaultAssetIndex(), 1);
    }

    function testQueuedRailOnlyAcceptsUnlockedRailDeposits() external view {
        assertFalse(qRail.getAsset(address(rail)).active);
        assertTrue(qRail.getAsset(address(manager.unlockedRail())).active);
    }

    function testQueuedRailAllocatorConfiguration() external view {
        bytes32 role = qRail.ALLOCATOR_ROLE();
        assertTrue(qRail.getHasAllocator());
        assertTrue(qRail.hasRole(role, address(strategy)));
        assertTrue(qRail.hasRole(role, address(withdrawer)));
        assertFalse(qRail.hasRole(role, address(processor)));
        assertFalse(qRail.hasRole(role, address(queuedRailProcessor)));
        assertFalse(qRail.hasRole(role, address(resolver)));
        assertFalse(qRail.hasRole(role, address(requests)));
        assertFalse(qRail.hasRole(role, user));
    }

    function testQueuedRailRejectsNonAllocatorDepositsAndWithdrawals() external {
        address unlockedRail = address(manager.unlockedRail());
        bytes memory expected =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", user, qRail.ALLOCATOR_ROLE());
        vm.expectRevert(expected);
        vm.prank(user);
        qRail.depositAsset(unlockedRail, 1000 ether, user);

        _deposit(user, 1000 ether);
        processor.rebalanceStaking(1);
        vm.startPrank(user);
        strategy.approve(address(processor), 1000 ether);
        processor.exitToQueuedRail(1000 ether, user, 1);
        vm.stopPrank();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.warp(block.timestamp + 30 days + 1);
        queuedRailProcessor.claimMaturedPositions(ids);

        vm.expectRevert(expected);
        vm.prank(user);
        qRail.withdraw(1000 ether, user, user);
        assertEq(qRail.balanceOf(user), 1000 ether);
        assertEq(rail.balanceOf(address(qRail)), 1000 ether);
    }

    function testAllocatorRevocationBlocksQueueAndSettlementUntilRestored() external {
        _deposit(user, 1000 ether);
        processor.rebalanceStaking(1);
        bytes32 role = qRail.ALLOCATOR_ROLE();
        qRail.revokeRole(role, address(strategy));
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.ProcessFailed.selector,
                abi.encodeCall(StakedRailStrategy.queuePosition, ()),
                abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", address(strategy), role)
            )
        );
        _queueThroughStrategy();
        assertEq(manager.activeRail().totalSupply(), 1000 ether);
        assertEq(manager.unlockedRail().totalSupply(), 0);

        qRail.grantRole(role, address(strategy));
        vm.startPrank(user);
        strategy.approve(address(processor), 1000 ether);
        processor.exitToQueuedRail(1000 ether, user, 1);
        qRail.approve(address(requests), 1000 ether);
        uint256 id = requests.requestWithdrawal(1000 ether, user, "");
        vm.stopPrank();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.warp(block.timestamp + 30 days + 1);
        queuedRailProcessor.claimMaturedPositions(ids);

        qRail.revokeRole(role, address(withdrawer));
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", address(withdrawer), role)
        );
        resolver.resolveRequests(1);
        assertEq(requests.requests(id).amountLocked, 1000 ether);
        assertEq(rail.balanceOf(requests.requests(id).bag), 0);
        qRail.grantRole(role, address(withdrawer));
        assertEq(resolver.resolveRequests(1), 1);
        assertEq(rail.balanceOf(requests.requests(id).bag), 1000 ether);
    }

    function testQueuedProcessorAndResolverHaveSeparatePermissions() external {
        bytes32 processorRole = qRail.PROCESSOR_ROLE();
        bytes32 resolverRole = requests.RESOLVER_ROLE();
        assertTrue(qRail.hasRole(processorRole, address(queuedRailProcessor)));
        assertFalse(qRail.hasRole(processorRole, address(resolver)));
        assertTrue(requests.hasRole(resolverRole, address(resolver)));
        assertFalse(requests.hasRole(resolverRole, address(queuedRailProcessor)));
        assertFalse(manager.hasRole(manager.CLAIMER_ROLE(), address(queuedRailProcessor)));
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", address(resolver), processorRole
            )
        );
        vm.prank(address(resolver));
        qRail.processor(new address[](0), new uint256[](0), new bytes[](0));
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", address(queuedRailProcessor), resolverRole
            )
        );
        vm.prank(address(queuedRailProcessor));
        requests.resolveWithdrawalRequest(0, address(rail), 1);
    }

    function testQueuedProcessorRequiresKeeperAndVaultProcessorRoles() external {
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", user, queuedRailProcessor.KEEPER_ROLE()
            )
        );
        vm.prank(user);
        queuedRailProcessor.claimMaturedPositions(ids);
        bytes32 role = qRail.PROCESSOR_ROLE();
        qRail.revokeRole(role, address(queuedRailProcessor));
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", address(queuedRailProcessor), role
            )
        );
        queuedRailProcessor.claimMaturedPositions(ids);
    }

    function testProcessorDependencies() external view {
        assertEq(address(processor.qRail()), address(strategy.queuedRail()));
        assertEq(address(processor.positionManager()), address(strategy.positionManager()));
        assertEq(address(queuedRailProcessor.qRail()), address(qRail));
        assertEq(address(queuedRailProcessor.positionManager()), address(manager));
    }

    function testProcessorRoleRevocationBlocksStakingAndQueueing() external {
        _deposit(user, 2000 ether);
        processor.rebalanceStaking(1);
        bytes32 role = strategy.PROCESSOR_ROLE();
        strategy.revokeRole(role, address(processor));
        bytes memory expected =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", address(processor), role);
        vm.expectRevert(expected);
        processor.rebalanceStaking(1);
        vm.prank(user);
        strategy.approve(address(processor), 1000 ether);
        vm.expectRevert(expected);
        vm.prank(user);
        processor.exitToQueuedRail(1000 ether, user, 1);
        assertEq(manager.activeRail().totalSupply(), 1000 ether);
        assertEq(manager.unlockedRail().totalSupply(), 0);
        assertEq(qRail.totalSupply(), 0);
        assertEq(strategy.balanceOf(user), 2000 ether);
    }

    function testDepositAndChunkedStakingAccounting() external {
        _deposit(user, 5000 ether);

        uint256 operations = processor.rebalanceStaking(10);

        assertEq(operations, 5);
        assertEq(rail.balanceOf(address(strategy)), 0);
        assertEq(manager.activeRail().totalSupply(), 5000 ether);
        assertEq(manager.unlockedRail().totalSupply(), 0);
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
        assertEq(manager.activeRail().totalSupply(), 2000 ether);
        assertEq(manager.unlockedRail().totalSupply(), 3000 ether);
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
        for (uint256 i = 0; i < 3; i++) {
            assertEq(ids[i], i);
        }
        assertEq(manager.activePositionCount(), 3);
        assertEq(manager.activeRail().totalSupply(), 3000 ether);
        assertEq(manager.unlockedRail().totalSupply(), 0);
        assertEq(qRail.totalSupply(), 0);
        assertEq(strategy.balanceOf(user), 3000 ether);
    }

    function testStakingFailureRollsBackCallerFundingAndApproval() external {
        _deposit(user, 1000 ether);
        vm.mockCallRevert(
            address(staking),
            abi.encodeCall(IRailgunStaking.stake, (1000 ether)),
            abi.encodeWithSignature("StakeFailed()")
        );
        vm.expectRevert();
        processor.rebalanceStaking(1);
        assertEq(rail.balanceOf(address(strategy)), 1000 ether);
        assertEq(rail.balanceOf(address(manager)), 0);
        assertEq(rail.allowance(address(strategy), address(manager)), 0);
        assertEq(rail.allowance(address(manager), address(staking)), 0);
        assertEq(manager.activePositionCount(), 0);
        assertEq(manager.activeRail().totalSupply(), 0);
    }

    function testStakingLeavesRemainderAndHonorsOperationLimit() external {
        _deposit(user, 2500 ether);
        vm.prank(user);
        assertEq(processor.rebalanceStaking(1), 1);
        assertEq(manager.activeRail().totalSupply(), 1000 ether);
        assertEq(rail.balanceOf(address(strategy)), 1500 ether);

        assertEq(processor.rebalanceStaking(10), 1);
        assertEq(processor.rebalanceStaking(10), 0);
        assertEq(manager.activeRail().totalSupply(), 2000 ether);
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
        assertEq(manager.activeRail().totalSupply(), 3000 ether);
        assertEq(manager.unlockedRail().totalSupply(), 2000 ether);

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

    function testResolverFullSettlementRoundingDustDoesNotBlockFifo() external {
        _deposit(user, 1000 ether);
        processor.rebalanceStaking(1);

        vm.startPrank(user);
        strategy.approve(address(processor), 1000 ether);
        processor.exitToQueuedRail(1000 ether, user, 1);
        qRail.approve(address(requests), 1000 ether);
        uint256 requestId = requests.requestWithdrawal(1000 ether, user, "");
        vm.stopPrank();

        uint256[] memory stakeIds = new uint256[](1);
        stakeIds[0] = 0;
        vm.warp(block.timestamp + 30 days + 1);
        queuedRailProcessor.claimMaturedPositions(stakeIds);

        // Simulate a 60% backing loss after the request is locked. A full 400 RAIL
        // settlement burns all but one wei of qRAIL, leaving dust.
        deal(address(rail), address(qRail), 400 ether);
        assertEq(qRail.previewRedeem(1000 ether), 400 ether);
        assertEq(qRail.previewWithdraw(400 ether), 1000 ether - 1);

        // Expected behavior: settle the available RAIL and advance the FIFO cursor despite dust.
        // Current behavior: SingleAssetFIFOResolver reverts IncompleteRedemption(requestId, 1).
        assertEq(resolver.resolveRequests(1), 1);
        assertEq(requests.requests(requestId).amountLocked, 0);
        assertEq(resolver.nextRequestToResolve(), requestId + 1);
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
