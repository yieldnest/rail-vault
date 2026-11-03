// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RailManagerDeploymentLib} from "../../script/libraries/RailDeploymentLib.sol";
import {RailRewardsProcessor} from "../../src/processors/RailRewardsProcessor.sol";
import {RailStakePositionManager} from "../../src/core/RailStakePositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRailgunGovernorRewards} from "../mocks/MockRailgunGovernorRewards.sol";
import {MockRailgunStaking} from "../mocks/MockRailgunStaking.sol";
import {MockSplitsSwapper} from "../mocks/MockSplitsSwapper.sol";

contract RailRewardsProcessorTest is Test {
    MockERC20 rail;
    MockERC20 reward;
    RailStakePositionManager manager;
    RailRewardsProcessor processor;
    MockSplitsSwapper splits;
    address receiver = makeAddr("railReceiver");
    address anyone = makeAddr("anyone");

    function setUp() external {
        rail = new MockERC20("RAIL", "RAIL", 18);
        reward = new MockERC20("Reward", "RWD", 18);
        manager = RailManagerDeploymentLib.deploy(address(rail), address(new MockRailgunStaking(rail)), address(this));
        splits = new MockSplitsSwapper(receiver, address(rail));
        processor = new RailRewardsProcessor(manager, address(splits));
        manager.grantRole(manager.TOKEN_WITHDRAWER_ROLE(), address(processor));
    }

    function _tokens(IERC20 token) internal pure returns (IERC20[] memory tokens) {
        tokens = new IERC20[](1);
        tokens[0] = token;
    }

    function testAnyoneCanForwardAfterSeparatePermissionlessClaim() external {
        MockRailgunGovernorRewards rewards = new MockRailgunGovernorRewards();
        rewards.setToken(reward, 10);
        rewards.setRewardAmount(reward, 3 ether);
        reward.mint(address(rewards), 100 ether);
        IERC20[] memory tokens = _tokens(reward);
        vm.prank(anyone);
        rewards.claim(tokens, address(manager), 2, 4, new uint256[](3));
        vm.prank(anyone);
        uint256[] memory amounts = processor.collectTokens(tokens);
        assertEq(amounts[0], 9 ether);
        assertEq(reward.balanceOf(address(splits)), 9 ether);
        assertEq(reward.balanceOf(address(manager)), 0);
        assertEq(reward.balanceOf(address(processor)), 0);
        assertEq(reward.balanceOf(anyone), 0);
        assertEq(reward.allowance(address(processor), address(splits)), 0);
    }

    function testRailBypassesSwapperAndFutureTokensNeedNoRegistry() external {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);
        MockERC20 future = new MockERC20("Future", "FUT", 6);
        IERC20[] memory tokens = new IERC20[](4);
        tokens[0] = rail;
        tokens[1] = dai;
        tokens[2] = weth;
        tokens[3] = future;
        rail.mint(address(manager), 1 ether);
        dai.mint(address(manager), 2 ether);
        weth.mint(address(manager), 3 ether);
        future.mint(address(manager), 4e6);
        vm.prank(anyone);
        uint256[] memory amounts = processor.collectTokens(tokens);
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(tokens[i].balanceOf(address(manager)), 0);
            assertEq(tokens[i].balanceOf(address(processor)), 0);
            assertEq(tokens[i].balanceOf(i == 0 ? receiver : address(splits)), amounts[i]);
        }
        assertEq(amounts[0], 1 ether);
        assertEq(amounts[3], 4e6);
        assertEq(rail.balanceOf(address(splits)), 0);
    }

    function testEmptyZeroBalanceAndDuplicateTokensAreHarmless() external {
        assertEq(processor.collectTokens(new IERC20[](0)).length, 0);
        assertEq(processor.collectTokens(_tokens(reward))[0], 0);
        reward.mint(address(manager), 5 ether);
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = reward;
        tokens[1] = reward;
        uint256[] memory amounts = processor.collectTokens(tokens);
        assertEq(amounts[0], 5 ether);
        assertEq(amounts[1], 0);
    }

    function testOnlyProcessorCanPullFromManager() external {
        reward.mint(address(manager), 1 ether);
        vm.expectRevert();
        vm.prank(anyone);
        manager.transferToken(reward, anyone, 1 ether);
        assertEq(reward.balanceOf(address(manager)), 1 ether);
    }

    function testRevokingProcessorRoleStopsForwarding() external {
        manager.revokeRole(manager.TOKEN_WITHDRAWER_ROLE(), address(processor));
        reward.mint(address(manager), 1 ether);
        vm.expectRevert();
        processor.collectTokens(_tokens(reward));
        assertEq(reward.balanceOf(address(manager)), 1 ether);
        assertEq(reward.balanceOf(address(splits)), 0);
    }

    function testInvalidTokenRollsBackWholeBatch() external {
        reward.mint(address(manager), 1 ether);
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = reward;
        tokens[1] = IERC20(address(0));
        vm.expectRevert(RailRewardsProcessor.ZeroAddress.selector);
        processor.collectTokens(tokens);
        assertEq(reward.balanceOf(address(manager)), 1 ether);
        assertEq(reward.balanceOf(address(splits)), 0);
    }

    function testRejectsInvalidDestinationsAndNonRailOutput() external {
        vm.expectRevert(RailRewardsProcessor.InvalidConfiguration.selector);
        new RailRewardsProcessor(manager, address(0));
        MockSplitsSwapper wrongOutput = new MockSplitsSwapper(receiver, address(reward));
        vm.expectRevert(RailRewardsProcessor.InvalidConfiguration.selector);
        new RailRewardsProcessor(manager, address(wrongOutput));
        MockSplitsSwapper wrongReceiver = new MockSplitsSwapper(address(manager), address(rail));
        vm.expectRevert(RailRewardsProcessor.InvalidConfiguration.selector);
        new RailRewardsProcessor(manager, address(wrongReceiver));
        MockSplitsSwapper zeroReceiver = new MockSplitsSwapper(address(0), address(rail));
        vm.expectRevert(RailRewardsProcessor.InvalidConfiguration.selector);
        new RailRewardsProcessor(manager, address(zeroReceiver));
    }

    function testHarvestAndArbitraryTransferEntryPointsAreRemoved() external {
        (bool harvestOk,) =
            address(processor).call(abi.encodeWithSignature("harvest(uint256,uint256[])", 0, new uint256[](0)));
        (bool transferOk,) = address(processor)
            .call(abi.encodeWithSignature("transferToken(address,address,uint256)", address(reward), anyone, 1));
        (bool keeperOk,) = address(processor).staticcall(abi.encodeWithSignature("KEEPER_ROLE()"));
        assertFalse(harvestOk);
        assertFalse(transferOk);
        assertFalse(keeperOk);
    }
}
