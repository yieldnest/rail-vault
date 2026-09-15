// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata as IERC20, SafeERC20} from "@yieldnest-vault/Common.sol";
import {BaseStrategy} from "@yieldnest-vault/strategy/BaseStrategy.sol";
import {VaultLib} from "@yieldnest-vault/library/VaultLib.sol";

import {RailProvider} from "./RailProvider.sol";

contract QueuedRailStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function initialize(address admin, address rail) external initializer {
        _initialize(admin, "Queued RAIL", "qRAIL", IERC20(rail).decimals(), false, false, true, 0);
        _addAsset(rail, IERC20(rail).decimals(), false);
        _setAssetWithdrawable(rail, false);
        VaultLib.setProvider(address(new RailProvider(rail)));
    }

    function maxDeposit(address) public pure override returns (uint256) {
        return 0;
    }

    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    function deposit(uint256, address) public pure override returns (uint256) {
        revert DepositsDisabled();
    }

    function mint(uint256, address) public pure override returns (uint256) {
        revert DepositsDisabled();
    }

    function depositAsset(address, uint256, address) public pure override returns (uint256) {
        revert DepositsDisabled();
    }

    function mintQueuedRail(address receiver, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(receiver, amount);
    }

    function burnQueuedRail(address owner, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(owner, amount);
    }

    function totalBaseAssets() public view override returns (uint256) {
        return totalSupply();
    }

    function computeTotalAssets() public view override returns (uint256) {
        return totalSupply();
    }

    function _feeOnRaw(uint256, address) public pure override returns (uint256) {
        return 0;
    }

    function _feeOnTotal(uint256, address) public pure override returns (uint256) {
        return 0;
    }

    error DepositsDisabled();
}
