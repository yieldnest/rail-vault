// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRailgunGovernorRewards} from "../../src/railgun/IRailgunGovernorRewards.sol";

contract MockRailgunGovernorRewards is IRailgunGovernorRewards {
    using SafeERC20 for IERC20;

    mapping(IERC20 token => bool supported) public override tokens;
    mapping(IERC20 token => uint256 interval) public override nextEarmarkInterval;
    mapping(IERC20 token => uint256 amount) public rewardAmount;
    mapping(address account => mapping(IERC20 token => mapping(uint256 interval => bool claimed))) public isClaimed;

    function setToken(IERC20 token, uint256 nextEarmarkInterval_) external {
        tokens[token] = true;
        nextEarmarkInterval[token] = nextEarmarkInterval_;
    }

    function setRewardAmount(IERC20 token, uint256 amount) external {
        rewardAmount[token] = amount;
    }

    function calculateRewards(
        IERC20[] calldata tokens_,
        address account,
        uint256 startingInterval,
        uint256 endingInterval,
        uint256[] calldata,
        bool ignoreClaimed
    ) external view returns (uint256[] memory rewards) {
        rewards = new uint256[](tokens_.length);
        for (uint256 i = 0; i < tokens_.length; i++) {
            IERC20 token = tokens_[i];
            require(endingInterval < nextEarmarkInterval[token], "not earmarked");
            uint256 total;
            for (uint256 interval = startingInterval; interval <= endingInterval; interval++) {
                if (!ignoreClaimed || !isClaimed[account][token][interval]) {
                    total += rewardAmount[token];
                }
            }
            rewards[i] = total;
        }
    }

    function claim(
        IERC20[] calldata tokens_,
        address account,
        uint256 startingInterval,
        uint256 endingInterval,
        uint256[] calldata
    ) external {
        IERC20 previousToken = IERC20(address(0));
        for (uint256 i = 0; i < tokens_.length; i++) {
            IERC20 token = tokens_[i];
            require(uint160(address(token)) > uint160(address(previousToken)), "unordered");
            require(endingInterval < nextEarmarkInterval[token], "not earmarked");
            uint256 total;
            for (uint256 interval = startingInterval; interval <= endingInterval; interval++) {
                if (!isClaimed[account][token][interval]) {
                    isClaimed[account][token][interval] = true;
                    total += rewardAmount[token];
                }
            }
            if (total != 0) token.safeTransfer(account, total);
            previousToken = token;
        }
    }
}
