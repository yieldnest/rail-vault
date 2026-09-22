// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RailRewardsProcessor} from "../../src/processors/RailRewardsProcessor.sol";
import {RailStakePositionManager} from "../../src/core/RailStakePositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRailgunGovernorRewards} from "../mocks/MockRailgunGovernorRewards.sol";
import {MockRailgunStaking} from "../mocks/MockRailgunStaking.sol";

contract RailRewardsProcessorTest is Test {
    MockERC20 rail;
    MockERC20 reward;
    MockRailgunStaking staking;
    MockRailgunGovernorRewards rewards;
    RailStakePositionManager manager;
    RailRewardsProcessor processor;

    function setUp() external {
        rail = new MockERC20("RAIL", "RAIL", 18);
        reward = new MockERC20("Reward", "RWD", 18);
        staking = new MockRailgunStaking(rail);
        rewards = new MockRailgunGovernorRewards();
        manager = new RailStakePositionManager(address(this), rail, staking);

        IERC20[] memory rewardTokens = _sortedRewardTokens();
        rewards.setToken(rewardTokens[0], 10);
        rewards.setRewardAmount(rewardTokens[0], 3 ether);
        reward.mint(address(rewards), 100 ether);

        processor = new RailRewardsProcessor(address(this), rewards, manager, rewardTokens, 2);
        manager.grantRole(manager.KEEPER_ROLE(), address(processor));
    }

    function testClaimableUsesManagerAccountAndConfiguredIntervals() external {
        uint256[] memory claimable = processor.claimable(4, new uint256[](3));

        assertEq(claimable.length, 1);
        assertEq(claimable[0], 9 ether);
    }

    function testHarvestClaimsToProcessorAndAdvancesCursor() external {
        uint256[] memory amounts = processor.harvest(4, new uint256[](3));

        assertEq(amounts.length, 1);
        assertEq(amounts[0], 9 ether);
        assertEq(processor.nextClaimInterval(), 5);
        assertEq(reward.balanceOf(address(processor)), 9 ether);
        assertEq(reward.balanceOf(address(manager)), 0);
        assertTrue(rewards.isClaimed(address(manager), reward, 2));
        assertTrue(rewards.isClaimed(address(manager), reward, 3));
        assertTrue(rewards.isClaimed(address(manager), reward, 4));
    }

    function _sortedRewardTokens() internal view returns (IERC20[] memory rewardTokens) {
        rewardTokens = new IERC20[](1);
        rewardTokens[0] = reward;
    }
}
