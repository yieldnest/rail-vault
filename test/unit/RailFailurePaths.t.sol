// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IBag} from "@yieldnest-vault-withdrawals/interface/IBag.sol";
import {WithdrawalRequest} from "@yieldnest-vault-withdrawals/WithdrawalRequest.sol";
import {RailStakePositionManager} from "../../src/core/RailStakePositionManager.sol";
import {RailReceiptToken} from "../../src/core/RailReceiptToken.sol";
import {IRailgunStaking} from "../../src/railgun/IRailgunStaking.sol";
import {StakedRailProcessor} from "../../src/processors/StakedRailProcessor.sol";
import {SingleAssetFIFOResolver} from "../../src/withdrawals/SingleAssetFIFOResolver.sol";
import {RailSystemFixture} from "../utils/RailSystemFixture.sol";

contract RailFailurePathsTest is RailSystemFixture {
    address internal alice = makeAddr("alice");

    function setUp() public {
        _deploySystem();
    }

    function testManagerInitializerRejectsEachZeroAddress() external {
        address implementation = address(new RailStakePositionManager());
        for (uint256 i; i < 4; ++i) {
            bytes memory data = abi.encodeCall(
                RailStakePositionManager.initialize,
                (
                    i == 0 ? address(0) : address(this),
                    IERC20(i == 1 ? address(0) : address(rail)),
                    IRailgunStaking(i == 2 ? address(0) : address(staking)),
                    i == 3 ? address(0) : address(this)
                )
            );
            vm.expectRevert(RailStakePositionManager.ZeroAddress.selector);
            new TransparentUpgradeableProxy(implementation, address(this), data);
        }
    }

    function testReceiptInitializerRejectsZeroManager() external {
        address implementation = address(new RailReceiptToken());
        vm.expectRevert(RailReceiptToken.ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            implementation,
            address(this),
            abi.encodeCall(RailReceiptToken.initialize, ("Receipt", "R", uint8(18), address(0)))
        );
    }

    function testResolverInitializerRejectsEitherZeroDependency() external {
        address implementation = address(new SingleAssetFIFOResolver());
        vm.expectRevert(SingleAssetFIFOResolver.ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            implementation,
            address(this),
            abi.encodeCall(SingleAssetFIFOResolver.initialize, (IERC4626(address(0)), d.withdrawalRequest))
        );
        vm.expectRevert(SingleAssetFIFOResolver.ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            implementation,
            address(this),
            abi.encodeCall(
                SingleAssetFIFOResolver.initialize, (IERC4626(address(d.qRail)), WithdrawalRequest(payable(address(0))))
            )
        );
    }

    function testExitRejectsZeroSharesAndZeroReceiver() external {
        vm.expectRevert(StakedRailProcessor.ZeroShares.selector);
        d.processor.exitToQueuedRail(0, alice, 1);
        vm.expectRevert(StakedRailProcessor.ZeroAddress.selector);
        d.processor.exitToQueuedRail(1, address(0), 1);
        assertEq(d.manager.activePositionCount(), 0);
        assertEq(d.qRail.totalSupply(), 0);
    }

    function testQueueRejectsUnexpectedExternalPositionStateAndRestoresHead() external {
        _deposit(alice, 1000 ether);
        d.processor.rebalanceStaking(1);
        // Simulate staking reporting a non-active entry for the manager's active head.
        vm.mockCall(
            address(staking),
            abi.encodeCall(IRailgunStaking.stakes, (address(d.manager), 0)),
            abi.encode(address(d.manager), 1000 ether, block.timestamp, block.timestamp + 30 days, 0)
        );
        vm.expectRevert(RailStakePositionManager.InvalidPositionStatus.selector);
        vm.prank(address(d.strategy));
        d.manager.queuePosition();
        vm.clearMockedCalls();
        assertEq(d.manager.activePositionCount(), 1);
        assertEq(d.manager.activeStakeHead(), 0);
        assertEq(d.manager.activeRail().balanceOf(address(d.strategy)), 1000 ether);
        assertEq(d.manager.unlockedRail().totalSupply(), 0);
        (,,, uint256 locktime,) = staking.stakes(address(d.manager), 0);
        assertEq(locktime, 0);
    }

    function testResolverSkipsAlreadySettledRequestWithinWorkLimit() external {
        _createTwoRequests();
        _settleFirstInKind();
        assertTrue(d.withdrawalRequest.requestExists(0));
        assertEq(d.resolver.resolveRequests(1), 0);
        assertEq(d.resolver.nextRequestToResolve(), 1);
        _assertSecondUntouched();
        _matureAndClaim();
        assertEq(d.resolver.resolveRequests(1), 1);
        assertEq(d.resolver.nextRequestToResolve(), 2);
        assertEq(rail.balanceOf(d.withdrawalRequest.requests(1).bag), 1000 ether);
    }

    function testResolverSkipsDeletedRequestWithinWorkLimit() external {
        _createTwoRequests();
        _settleFirstInKind();
        address bag = d.withdrawalRequest.requests(0).bag;
        address[] memory assets = new address[](1);
        assets[0] = address(d.qRail);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000 ether;
        vm.startPrank(alice);
        IBag(bag).claim(assets, payable(alice), amounts);
        d.withdrawalRequest.burn(0);
        vm.stopPrank();
        assertFalse(d.withdrawalRequest.requestExists(0));
        assertEq(d.resolver.resolveRequests(1), 0);
        assertEq(d.resolver.nextRequestToResolve(), 1);
        _assertSecondUntouched();
        _matureAndClaim();
        assertEq(d.resolver.resolveRequests(1), 1);
        assertEq(d.resolver.nextRequestToResolve(), 2);
    }

    function testResolverZeroWorkLimitLeavesFundedQueueUntouched() external {
        _createTwoRequests();
        _matureAndClaim();
        assertEq(d.resolver.resolveRequests(0), 0);
        assertEq(d.resolver.nextRequestToResolve(), 0);
        assertEq(d.withdrawalRequest.requests(0).amountLocked, 1000 ether);
        assertEq(rail.balanceOf(d.withdrawalRequest.requests(0).bag), 0);
        _assertSecondUntouched();
    }

    function testIncompleteResidualSettlementRollsBackEntireRequest() external {
        _createTwoRequests();
        _matureAndClaim();
        // A loss creates residual shares after withdrawing the full RAIL quote.
        deal(address(rail), address(d.qRail), 400 ether);
        uint256 amount = d.qRail.previewRedeem(1000 ether);
        uint256 residual = 1000 ether - d.qRail.previewWithdraw(amount);
        assertGt(residual, 0);
        uint256 supply = d.qRail.totalSupply();
        address bag = d.withdrawalRequest.requests(0).bag;
        // A broken/upgraded settlement dependency reports no progress on the residual.
        vm.mockCall(
            address(d.withdrawalRequest),
            abi.encodeWithSignature("resolveWithdrawalRequest(uint256,address,uint256)", 0, address(d.qRail), residual),
            abi.encode(uint256(0))
        );
        vm.expectRevert(abi.encodeWithSelector(SingleAssetFIFOResolver.IncompleteRedemption.selector, 0, residual));
        d.resolver.resolveRequests(1);
        assertEq(d.resolver.nextRequestToResolve(), 0);
        assertEq(d.withdrawalRequest.requests(0).amountLocked, 1000 ether);
        assertEq(d.qRail.totalSupply(), supply);
        assertEq(d.qRail.balanceOf(address(d.withdrawalRequest)), 2000 ether);
        assertEq(rail.balanceOf(address(d.qRail)), 400 ether);
        assertEq(rail.balanceOf(bag), 0);
        assertEq(d.qRail.balanceOf(bag), 0);
        _assertSecondUntouched();
        vm.clearMockedCalls();
        assertEq(d.resolver.resolveRequests(1), 1);
        assertEq(d.withdrawalRequest.requests(0).amountLocked, 0);
        assertEq(rail.balanceOf(bag), amount);
        assertEq(d.qRail.balanceOf(bag), residual);
    }

    function _createTwoRequests() internal {
        _bootstrapSystem();
        _deposit(alice, 3000 ether);
        d.processor.rebalanceStaking(3);
        _exit(alice, 2000 ether, 2);
        vm.startPrank(alice);
        d.qRail.approve(address(d.withdrawalRequest), 2000 ether);
        d.withdrawalRequest.requestWithdrawal(1000 ether, alice);
        d.withdrawalRequest.requestWithdrawal(1000 ether, alice);
        vm.stopPrank();
    }

    function _settleFirstInKind() internal {
        // Another authorized resolver completes the head before our FIFO resolver sees it.
        d.withdrawalRequest.grantRole(d.withdrawalRequest.RESOLVER_ROLE(), address(this));
        d.withdrawalRequest.resolveWithdrawalRequest(0, address(d.qRail), 1000 ether);
        assertEq(d.withdrawalRequest.requests(0).amountLocked, 0);
    }

    function _assertSecondUntouched() internal view {
        WithdrawalRequest.Request memory second = d.withdrawalRequest.requests(1);
        assertEq(second.amountLocked, 1000 ether);
        assertEq(rail.balanceOf(second.bag), 0);
        assertEq(d.qRail.balanceOf(second.bag), 0);
    }

    function _matureAndClaim() internal {
        vm.warp(block.timestamp + 30 days + 1);
        uint256[] memory ids = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            ids[i] = i;
        }
        d.queuedRailProcessor.claimMaturedPositions(ids);
    }
}
