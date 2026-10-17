// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Funding destination only; does not simulate Splits oracle or swap execution.
contract MockSplitsSwapper {
    address public immutable beneficiary;
    address public immutable tokenToBeneficiary;

    constructor(address receiver, address outputToken) {
        beneficiary = receiver;
        tokenToBeneficiary = outputToken;
    }
}
