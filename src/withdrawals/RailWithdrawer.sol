// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseWithdrawer} from "@yieldnest-vault-withdrawals/withdrawers/BaseWithdrawer.sol";

contract RailWithdrawer is BaseWithdrawer {
    IERC20 public rail;

    function initialize(address queuedRail, address withdrawalRequest, address railAddress) external initializer {
        __BaseWithdrawer_init(queuedRail, withdrawalRequest);
        if (railAddress == address(0)) revert ZeroAddress();
        rail = IERC20(railAddress);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256 assets) {
        return token().convertToAssets(shares);
    }
}
