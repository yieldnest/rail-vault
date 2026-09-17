// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRailgunGovernorRewards} from "../railgun/IRailgunGovernorRewards.sol";
import {RailStakePositionManager} from "../railgun/RailStakePositionManager.sol";

contract RailRewardsProcessor is AccessControl {
    bytes32 public constant CONFIG_MANAGER_ROLE = keccak256("CONFIG_MANAGER_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    IRailgunGovernorRewards public immutable rewards;
    RailStakePositionManager public immutable positionManager;

    IERC20[] private rewardTokens;
    mapping(IERC20 token => bool supported) public isRewardToken;
    uint256 public nextClaimInterval;

    event RewardTokensSet(IERC20[] tokens);
    event NextClaimIntervalSet(uint256 nextClaimInterval);
    event RewardsHarvested(uint256 startingInterval, uint256 endingInterval, uint256[] amounts);

    constructor(
        address admin,
        IRailgunGovernorRewards rewardsAddress,
        RailStakePositionManager positionManagerAddress,
        IERC20[] memory rewardTokens_,
        uint256 nextClaimInterval_
    ) {
        if (address(rewardsAddress) == address(0) || address(positionManagerAddress) == address(0)) {
            revert ZeroAddress();
        }
        rewards = rewardsAddress;
        positionManager = positionManagerAddress;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_MANAGER_ROLE, admin);
        _grantRole(KEEPER_ROLE, admin);
        _setRewardTokens(rewardTokens_);
        _setNextClaimInterval(nextClaimInterval_);
    }

    function rewardTokenCount() external view returns (uint256) {
        return rewardTokens.length;
    }

    function rewardTokenAt(uint256 index) external view returns (IERC20) {
        return rewardTokens[index];
    }

    function rewardTokensList() external view returns (IERC20[] memory) {
        return rewardTokens;
    }

    function claimable(uint256 endingInterval, uint256[] calldata hints) external view returns (uint256[] memory) {
        return rewards.calculateRewards(
            rewardTokens, address(positionManager), nextClaimInterval, endingInterval, hints, true
        );
    }

    function harvest(uint256 endingInterval, uint256[] calldata hints)
        external
        onlyRole(KEEPER_ROLE)
        returns (uint256[] memory amounts)
    {
        if (endingInterval < nextClaimInterval) revert InvalidIntervalRange();
        _validateRewardTokens(endingInterval);

        uint256 startingInterval = nextClaimInterval;
        amounts =
            positionManager.claimRewards(rewards, rewardTokens, startingInterval, endingInterval, hints, address(this));

        // TODO: Auto-compound claimed rewards. RAIL rewards should be routed back into the staking flow,
        // and non-RAIL rewards need an explicit hold/swap/accounting policy before compounding.
        nextClaimInterval = endingInterval + 1;
        emit RewardsHarvested(startingInterval, endingInterval, amounts);
    }

    function setRewardTokens(IERC20[] calldata rewardTokens_) external onlyRole(CONFIG_MANAGER_ROLE) {
        _setRewardTokens(rewardTokens_);
    }

    function setNextClaimInterval(uint256 nextClaimInterval_) external onlyRole(CONFIG_MANAGER_ROLE) {
        _setNextClaimInterval(nextClaimInterval_);
    }

    function _setRewardTokens(IERC20[] memory rewardTokens_) internal {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            isRewardToken[rewardTokens[i]] = false;
        }
        delete rewardTokens;

        IERC20 previousToken = IERC20(address(0));
        for (uint256 i = 0; i < rewardTokens_.length; i++) {
            IERC20 token = rewardTokens_[i];
            if (address(token) == address(0) || uint160(address(token)) <= uint160(address(previousToken))) {
                revert InvalidRewardTokens();
            }
            if (!rewards.tokens(token)) revert UnsupportedRewardToken();
            rewardTokens.push(token);
            isRewardToken[token] = true;
            previousToken = token;
        }
        emit RewardTokensSet(rewardTokens_);
    }

    function _setNextClaimInterval(uint256 nextClaimInterval_) internal {
        nextClaimInterval = nextClaimInterval_;
        emit NextClaimIntervalSet(nextClaimInterval_);
    }

    function _validateRewardTokens(uint256 endingInterval) internal view {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            IERC20 token = rewardTokens[i];
            if (!rewards.tokens(token)) revert UnsupportedRewardToken();
            if (endingInterval >= rewards.nextEarmarkInterval(token)) revert IntervalNotEarmarked();
        }
    }

    error ZeroAddress();
    error InvalidRewardTokens();
    error UnsupportedRewardToken();
    error InvalidIntervalRange();
    error IntervalNotEarmarked();
}
