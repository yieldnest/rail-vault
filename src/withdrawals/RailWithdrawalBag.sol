// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract RailWithdrawalBag {
    using SafeERC20 for IERC20;

    IERC20 public immutable rail;
    address public immutable withdrawalRequest;

    constructor(IERC20 rail_, address withdrawalRequest_) {
        rail = rail_;
        withdrawalRequest = withdrawalRequest_;
    }

    function release(address receiver, uint256 amount) external {
        if (msg.sender != withdrawalRequest) revert OnlyWithdrawalRequest();
        rail.safeTransfer(receiver, amount);
    }

    error OnlyWithdrawalRequest();
}
