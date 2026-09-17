// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata as IERC20} from "@yieldnest-vault/Common.sol";
import {BaseStrategy} from "@yieldnest-vault/strategy/BaseStrategy.sol";
import {VaultLib} from "@yieldnest-vault/library/VaultLib.sol";

import {RailProvider} from "./RailProvider.sol";

contract QueuedRailStrategy is BaseStrategy {
    function initialize(address admin, address rail) external initializer {
        _initialize(admin, "Queued RAIL", "qRAIL", IERC20(rail).decimals(), false, false, true, 0);
        _addAsset(rail, IERC20(rail).decimals(), false);
        _setAssetWithdrawable(rail, false);
        VaultLib.setProvider(address(new RailProvider(rail, address(0))));
    }

    function processorMintShares(address receiver, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlyProcessorSelfCall();
        _mint(receiver, amount);
    }

    function processorBurnShares(address owner, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlyProcessorSelfCall();
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

    error OnlyProcessorSelfCall();
}
