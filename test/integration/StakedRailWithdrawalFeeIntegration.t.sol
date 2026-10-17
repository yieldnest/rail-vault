// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBag} from "@yieldnest-vault-withdrawals/interface/IBag.sol";
import {IRailgunStaking} from "../../src/railgun/IRailgunStaking.sol";
import {StakedRailStrategy} from "../../src/core/StakedRailStrategy.sol";
import {RailStrategyDeployer} from "../../script/RailStrategyDeployer.sol";
import {MockSplitsSwapper} from "../mocks/MockSplitsSwapper.sol";

contract StakedRailWithdrawalFeeIntegrationTest is Test {
    address internal constant STAKING = 0xEE6A649Aa3766bD117e12C161726b693A1B2Ee20;
    // YieldNest uses a 1e8 fee scale: 10_000 = 0.01% = 1 basis point.
    uint64 internal constant WITHDRAWAL_FEE = 10_000;
    address internal alice = makeAddr("alice");
    IERC20 internal rail;
    RailStrategyDeployer.Deployed internal d;

    function setUp() external {
        rail = IERC20(IRailgunStaking(STAKING).stakingToken());
        RailStrategyDeployer deployer = new RailStrategyDeployer(
            RailStrategyDeployer.Config({
                admin: address(this),
                rail: address(rail),
                staking: STAKING,
                splitsSwapper: address(new MockSplitsSwapper(address(this), address(rail))),
                stakeChunkSize: 1000 ether,
                unpause: true
            })
        );
        d = deployer.deploy();
        d.strategy.setBaseWithdrawalFee(WITHDRAWAL_FEE);
        deal(address(rail), alice, 5000 ether);
        vm.startPrank(alice);
        rail.approve(address(d.strategy), 5000 ether);
        assertEq(d.strategy.deposit(5000 ether, alice), 5000 ether);
        vm.stopPrank();
        assertEq(d.processor.rebalanceStaking(5), 5);
    }

    function testProcessorExitFeeRetainedThroughNftSettlement() external {
        assertEq(d.strategy.baseWithdrawalFee(), WITHDRAWAL_FEE);
        uint256 shares = 1500 ether;
        uint256 fee = (shares + 10_001 - 1) / 10_001;
        uint256 expected = shares - fee;
        vm.startPrank(alice);
        d.strategy.approve(address(d.processor), shares);
        uint256 received = d.processor.exitToQueuedRail(shares, alice, 2);
        assertEq(received, expected);
        d.qRail.approve(address(d.withdrawalRequest), received);
        uint256 id = d.withdrawalRequest.requestWithdrawal(received, alice, "fee");
        vm.stopPrank();

        assertEq(d.strategy.totalSupply(), 3500 ether);
        assertEq(d.strategy.totalAssets(), 3500 ether + fee);
        assertEq(d.qRail.balanceOf(address(d.strategy)), 500 ether + fee);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
        (,,, uint256 locktime,) = IRailgunStaking(STAKING).stakes(address(d.manager), 1);
        vm.warp(locktime + 1);
        assertEq(d.queuedRailProcessor.claimMaturedPositions(ids), 2000 ether);
        assertEq(d.resolver.resolveRequests(1), 1);
        address bag = d.withdrawalRequest.requests(id).bag;
        assertEq(d.withdrawalRequest.requests(id).amountLocked, 0);
        assertEq(rail.balanceOf(bag), expected);

        address[] memory assets = new address[](1);
        assets[0] = address(rail);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = expected;
        vm.prank(alice);
        IBag(bag).claim(assets, payable(alice), amounts);
        assertEq(rail.balanceOf(alice), expected);
        assertEq(d.strategy.totalAssets(), 3500 ether + fee);
    }

    function testDirectWithdrawChargesOneBasisPoint() external {
        _queuePosition();
        vm.prank(alice);
        assertEq(d.strategy.withdrawAsset(address(d.qRail), 1000 ether, alice, alice), 1000.1 ether);
        assertEq(d.qRail.balanceOf(alice), 1000 ether);
        assertEq(d.strategy.totalSupply(), 3999.9 ether);
        assertEq(d.strategy.totalAssets(), 4000 ether);
    }

    function testFuzzDirectRedeemRetainsRoundedFee(uint256 shares) external {
        shares = bound(shares, 1, 1000 ether);
        _queuePosition();
        uint256 fee = (shares + 10_001 - 1) / 10_001;
        uint256 expected = shares - fee;
        vm.prank(alice);
        assertEq(d.strategy.redeemAsset(address(d.qRail), shares, alice, alice), expected);
        assertEq(d.qRail.balanceOf(alice), expected);
        assertEq(d.strategy.totalAssets(), 5000 ether - expected);
        assertEq(d.strategy.totalSupply(), 5000 ether - shares);
    }

    function _queuePosition() internal {
        address[] memory targets = new address[](1);
        targets[0] = address(d.strategy);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeCall(StakedRailStrategy.queuePosition, ());
        vm.prank(address(d.processor));
        d.strategy.processor(targets, values, data);
    }
}
