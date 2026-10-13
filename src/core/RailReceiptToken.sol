// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract RailReceiptToken is ERC20Upgradeable {
    address public manager;
    uint8 private receiptDecimals;

    error OnlyManager();
    error ZeroAddress();

    constructor() {
        _disableInitializers();
    }

    function initialize(string memory name_, string memory symbol_, uint8 decimals_, address manager_)
        external
        initializer
    {
        if (manager_ == address(0)) revert ZeroAddress();
        __ERC20_init(name_, symbol_);
        manager = manager_;
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
