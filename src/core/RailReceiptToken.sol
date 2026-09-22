// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract RailReceiptToken is ERC20 {
    address public immutable manager;
    uint8 private immutable receiptDecimals;

    error OnlyManager();

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        manager = msg.sender;
        receiptDecimals = decimals_;
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert OnlyManager();
        _;
    }

    function decimals() public view override returns (uint8) {
        return receiptDecimals;
    }

    function mint(address receiver, uint256 amount) external onlyManager {
        _mint(receiver, amount);
    }

    function burn(address owner, uint256 amount) external onlyManager {
        _burn(owner, amount);
    }
}
