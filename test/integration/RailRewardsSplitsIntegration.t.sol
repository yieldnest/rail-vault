// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RailManagerDeploymentLib} from "../../script/libraries/RailDeploymentLib.sol";
import {RailStakePositionManager} from "../../src/core/RailStakePositionManager.sol";
import {RailRewardsProcessor} from "../../src/processors/RailRewardsProcessor.sol";
import {
    SplitsMainnet,
    SplitsPair,
    SplitsQuote,
    ISplitsOracleMainnet,
    ISplitsSwapperMainnet,
    ISplitsUniV3Mainnet
} from "../utils/SplitsMainnet.sol";

contract RailRewardsSplitsIntegrationTest is Test {
    address constant STAKING = 0xEE6A649Aa3766bD117e12C161726b693A1B2Ee20;
    uint128 constant AMOUNT = 0.01 ether;
    address beneficiary = makeAddr("beneficiary");
    address collector = makeAddr("permissionlessCollector");
    address trader = makeAddr("permissionlessTrader");
    RailStakePositionManager manager;
    RailRewardsProcessor processor;
    address swapper;
    address oracle;

    function setUp() external {
        (swapper, oracle) = SplitsMainnet.create(beneficiary);
        manager = RailManagerDeploymentLib.deploy(SplitsMainnet.RAIL, STAKING, address(this));
        processor = new RailRewardsProcessor(manager, swapper);
        manager.grantRole(manager.TOKEN_WITHDRAWER_ROLE(), address(processor));
        assertEq(processor.splitsSwapper(), swapper);
        assertEq(processor.railReceiver(), beneficiary);
        assertEq(ISplitsSwapperMainnet(swapper).oracle(), oracle);
    }

    function _fundSwapper() internal {
        // Seed already-claimed rewards; the separate real-claim test covers the distributor.
        deal(SplitsMainnet.WETH, address(manager), AMOUNT);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(SplitsMainnet.WETH);
        vm.prank(collector);
        uint256[] memory amounts = processor.collectTokens(tokens);
        assertEq(amounts[0], AMOUNT);
        assertEq(IERC20(SplitsMainnet.WETH).balanceOf(swapper), AMOUNT);
        assertEq(IERC20(SplitsMainnet.WETH).balanceOf(address(manager)), 0);
        assertEq(IERC20(SplitsMainnet.WETH).balanceOf(address(processor)), 0);
    }

    function _params() internal view returns (ISplitsUniV3Mainnet.InitFlash memory params) {
        params.quoteParams = new SplitsQuote[](1);
        params.quoteParams[0] = SplitsQuote(SplitsPair(SplitsMainnet.WETH, SplitsMainnet.RAIL), AMOUNT, "");
        params.flashCallbackData.excessRecipient = trader;
        params.flashCallbackData.exactInputParams = new ISplitsUniV3Mainnet.ExactInput[](1);
        // Deliberately zero router minimum: the independent Splits oracle obligation
        // must enforce payment even when the untrusted trader supplies no router floor.
        params.flashCallbackData.exactInputParams[0] = ISplitsUniV3Mainnet.ExactInput(
            abi.encodePacked(SplitsMainnet.WETH, uint24(10000), SplitsMainnet.RAIL),
            SplitsMainnet.INTEGRATION,
            block.timestamp,
            AMOUNT,
            0
        );
    }

    function testPermissionlessForwardAndRealUniV3SettlementToRail() external {
        _fundSwapper();
        ISplitsUniV3Mainnet.InitFlash memory params = _params();
        uint256 quoted = ISplitsOracleMainnet(oracle).getQuoteAmounts(params.quoteParams)[0];
        uint256 required = quoted * 950_000 / 1_000_000;
        assertGt(required, 0);
        uint256 beforeBalance = IERC20(SplitsMainnet.RAIL).balanceOf(beneficiary);
        vm.prank(trader);
        ISplitsUniV3Mainnet(SplitsMainnet.INTEGRATION).initFlash(swapper, params);
        assertEq(IERC20(SplitsMainnet.RAIL).balanceOf(beneficiary) - beforeBalance, required);
        assertGt(IERC20(SplitsMainnet.RAIL).balanceOf(trader), 0);
        assertEq(IERC20(SplitsMainnet.WETH).balanceOf(swapper), 0);
        assertEq(IERC20(SplitsMainnet.RAIL).balanceOf(address(processor)), 0);
        assertEq(IERC20(SplitsMainnet.RAIL).balanceOf(SplitsMainnet.INTEGRATION), 0);
        assertEq(IERC20(SplitsMainnet.WETH).balanceOf(SplitsMainnet.INTEGRATION), 0);
    }

    function testOracleUnderpaymentRevertsEvenWithZeroRouterMinimum() external {
        _fundSwapper();
        // Test owner deliberately makes the oracle obligation impossible for this swap.
        ISplitsSwapperMainnet(swapper).setDefaultScaledOfferFactor(2_000_000);
        ISplitsUniV3Mainnet.InitFlash memory params = _params();
        vm.expectRevert(bytes4(keccak256("InsufficientFunds()")));
        vm.prank(trader);
        ISplitsUniV3Mainnet(SplitsMainnet.INTEGRATION).initFlash(swapper, params);
        assertEq(IERC20(SplitsMainnet.WETH).balanceOf(swapper), AMOUNT);
        assertEq(IERC20(SplitsMainnet.RAIL).balanceOf(beneficiary), 0);
        assertEq(IERC20(SplitsMainnet.RAIL).balanceOf(trader), 0);
    }

    function testRailBypassesRealSwapper() external {
        deal(SplitsMainnet.RAIL, address(manager), 10 ether);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(SplitsMainnet.RAIL);
        vm.prank(collector);
        processor.collectTokens(tokens);
        assertEq(IERC20(SplitsMainnet.RAIL).balanceOf(beneficiary), 10 ether);
        assertEq(IERC20(SplitsMainnet.RAIL).balanceOf(swapper), 0);
    }
}
