// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IRequestPolicy} from "@yieldnest-vault-withdrawals/interface/IRequestPolicy.sol";

/// @notice Upgradeable equivalent of the withdrawal dependency's minimum-share policy.
contract RailMinAmountRequestPolicy is Initializable, IRequestPolicy {
    uint256 public minWithdrawalAmount;
    uint256[50] private __gap;

    error AmountBelowMinimum(uint256 amount, uint256 minWithdrawalAmount);

    constructor() {
        _disableInitializers();
    }

    function initialize(uint256 minWithdrawalAmount_) external initializer {
        minWithdrawalAmount = minWithdrawalAmount_;
    }

    function validateRequest(address, address, uint256 amount, bytes calldata) external view {
        if (amount < minWithdrawalAmount) revert AmountBelowMinimum(amount, minWithdrawalAmount);
    }
}
