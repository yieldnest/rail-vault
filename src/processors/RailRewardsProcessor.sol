// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RailStakePositionManager} from "../core/RailStakePositionManager.sol";

interface ISplitsSwapper {
    function beneficiary() external view returns (address);
    function tokenToBeneficiary() external view returns (address);
}

/// @notice Permissionlessly forwards already-claimed rewards to fixed destinations.
/// @dev No claims, swaps, approvals or caller-selected recipients. Governance must
/// configure Splits pricing separately and retain the configured RAIL beneficiary.
contract RailRewardsProcessor is ReentrancyGuard {
    RailStakePositionManager public immutable positionManager;
    address public immutable splitsSwapper;
    address public immutable railReceiver;
    IERC20 public immutable rail;

    event TokenCollected(address indexed token, address indexed receiver, uint256 amount);
    error InvalidConfiguration();
    error ZeroAddress();

    constructor(RailStakePositionManager manager, address swapper) {
        if (address(manager).code.length == 0 || swapper.code.length == 0 || swapper == address(manager)) {
            revert InvalidConfiguration();
        }
        IERC20 railToken = manager.rail();
        address receiver = ISplitsSwapper(swapper).beneficiary();
        if (
            ISplitsSwapper(swapper).tokenToBeneficiary() != address(railToken) || receiver == address(0)
                || receiver == address(manager) || receiver == address(this) || receiver == swapper
        ) revert InvalidConfiguration();
        positionManager = manager;
        splitsSwapper = swapper;
        railReceiver = receiver;
        rail = railToken;
    }

    /// @notice Anyone may forward the manager's complete balance of any ERC20.
    /// @return amounts Actual amounts received at each destination.
    function collectTokens(IERC20[] calldata tokens) external nonReentrant returns (uint256[] memory amounts) {
        amounts = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            IERC20 token = tokens[i];
            if (address(token) == address(0)) revert ZeroAddress();
            uint256 amount = token.balanceOf(address(positionManager));
            if (amount == 0) continue;
            // RAIL goes to railReceiver, cached at deployment; other tokens go to the Swapper,
            // whose owner can independently change its beneficiary and output token. Those
            // changes do not update railReceiver and are not revalidated here.
            address receiver = token == rail ? railReceiver : splitsSwapper;
            uint256 beforeBalance = token.balanceOf(receiver);
            positionManager.transferToken(token, receiver, amount);
            amounts[i] = token.balanceOf(receiver) - beforeBalance;
            emit TokenCollected(address(token), receiver, amounts[i]);
        }
    }
}
