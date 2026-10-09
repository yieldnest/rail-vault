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
        manager.grantRole(manager.TOKEN_WITHDRAWER_ROLE(), address(processor));
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

    function testHarvestCollectsRewardsClaimedByAnotherCaller() external {
        vm.prank(makeAddr("anyone"));
        rewards.claim(_sortedRewardTokens(), address(manager), 2, 4, new uint256[](3));
        assertEq(reward.balanceOf(address(manager)), 9 ether);
        assertEq(processor.claimable(4, new uint256[](3))[0], 0);

        uint256[] memory amounts = processor.harvest(4, new uint256[](3));
        assertEq(amounts[0], 9 ether);
        assertEq(reward.balanceOf(address(manager)), 0);
        assertEq(reward.balanceOf(address(processor)), 9 ether);
        assertEq(processor.nextClaimInterval(), 5);
    }

    function testCollectTokensWithoutClaimOrRewardRegistration() external {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);
        IERC20[] memory tokens = new IERC20[](4);
        tokens[0] = rail;
        tokens[1] = dai;
        tokens[2] = weth;
        tokens[3] = reward;
        rail.mint(address(manager), 1 ether);
        dai.mint(address(manager), 2 ether);
        weth.mint(address(manager), 3 ether);
        reward.mint(address(manager), 4 ether);
        processor.setRewardTokens(new IERC20[](0));

        uint256[] memory amounts = processor.collectTokens(tokens);
        for (uint256 i = 0; i < tokens.length; i++) {
            assertEq(amounts[i], (i + 1) * 1 ether);
            assertEq(tokens[i].balanceOf(address(manager)), 0);
            assertEq(tokens[i].balanceOf(address(processor)), amounts[i]);
        }
        assertEq(processor.nextClaimInterval(), 2);
        amounts = processor.collectTokens(tokens);
        for (uint256 i = 0; i < amounts.length; i++) {
            assertEq(amounts[i], 0);
        }
    }

    function testKeeperCanForwardCollectedTokens() external {
        reward.mint(address(manager), 5 ether);
        processor.collectTokens(_sortedRewardTokens());
        address receiver = makeAddr("receiver");
        processor.transferToken(reward, receiver, 3 ether);
        assertEq(reward.balanceOf(receiver), 3 ether);
        assertEq(reward.balanceOf(address(processor)), 2 ether);
    }

    function testCollectionAndForwardingRequireKeeper() external {
        address stranger = makeAddr("stranger");
        bytes memory errorData = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", stranger, processor.KEEPER_ROLE()
        );
        IERC20[] memory tokens = _sortedRewardTokens();
        vm.expectRevert(errorData);
        vm.prank(stranger);
        processor.collectTokens(tokens);
        vm.expectRevert(errorData);
        vm.prank(stranger);
        processor.transferToken(reward, stranger, 1);
    }

    function testCollectionFailureRollsBackClaimAndCursor() external {
        manager.revokeRole(manager.TOKEN_WITHDRAWER_ROLE(), address(processor));
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", address(processor), manager.TOKEN_WITHDRAWER_ROLE()
            )
        );
        processor.harvest(4, new uint256[](3));
        assertEq(processor.nextClaimInterval(), 2);
        assertFalse(rewards.isClaimed(address(manager), reward, 2));
        assertEq(reward.balanceOf(address(manager)), 0);
        assertEq(reward.balanceOf(address(processor)), 0);
    }
}
