// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseWithdrawer} from "@yieldnest-vault-withdrawals/withdrawers/BaseWithdrawer.sol";

import {QueuedRailStrategy} from "../QueuedRailStrategy.sol";

contract RailWithdrawer is BaseWithdrawer {
    using SafeERC20 for IERC20;

    IERC20 public rail;
    QueuedRailStrategy public queuedRail;

    event Settled(uint256 indexed requestId, address indexed bag, uint256 amount);

    function initialize(address queuedRail_, address withdrawalRequest_, address rail_) external initializer {
        __BaseWithdrawer_init(queuedRail_, withdrawalRequest_);
        if (rail_ == address(0)) revert ZeroAddress();
        rail = IERC20(rail_);
        queuedRail = QueuedRailStrategy(payable(queuedRail_));
    }

    function withdrawAsset(uint256 requestId, address asset, uint256 assets, address receiver, address owner)
        external
        override
        onlyWithdrawalRequest
        returns (uint256 shares)
    {
        if (asset != address(rail)) revert UnsupportedAsset(asset);
        if (rail.balanceOf(address(this)) < assets) revert InsufficientRAIL();

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(queuedRail);
        data[0] = abi.encodeCall(QueuedRailStrategy.processorBurnShares, (owner, assets));
        queuedRail.processor(targets, values, data);

        rail.safeTransfer(receiver, assets);
        emit Settled(requestId, receiver, assets);
        return assets;
    }

    function convertToAssets(uint256 shares) public pure override returns (uint256 assets) {
        return shares;
    }

    error UnsupportedAsset(address asset);
    error InsufficientRAIL();
}
