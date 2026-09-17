// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseWithdrawer} from "@yieldnest-vault-withdrawals/withdrawers/BaseWithdrawer.sol";

contract RailWithdrawer is BaseWithdrawer {
    IERC20 public rail;

    function initialize(address queuedRail_, address withdrawalRequest_, address rail_) external initializer {
        __BaseWithdrawer_init(queuedRail_, withdrawalRequest_);
        if (rail_ == address(0)) revert ZeroAddress();
        rail = IERC20(rail_);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256 assets) {
        return token().convertToAssets(shares);
    }
}
