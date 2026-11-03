// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseStrategy} from "@yieldnest-vault/strategy/BaseStrategy.sol";

// NOTE: Seed qRAIL with a meaningful amount of permanently locked shares before enabling exits.
// This mitigates donation-driven rate inflation that can make stRAIL exits return zero qRAIL
// or make queue deposits round to zero shares. Seeding does not replace zero-output checks.
contract QueuedRailStrategy is BaseStrategy {
    string public constant Q_RAIL_VERSION = "0.1.0";

    function initialize(
        address admin,
        string memory name,
        string memory symbol,
        uint8 decimals_,
        bool paused_,
        bool countNativeAsset_,
        bool alwaysComputeTotalAssets_,
        uint256 defaultAssetIndex_
    ) external initializer {
        _initialize(
            admin, name, symbol, decimals_, paused_, countNativeAsset_, alwaysComputeTotalAssets_, defaultAssetIndex_
        );
    }

    function _feeOnRaw(uint256, address) public pure override returns (uint256) {
        return 0;
    }

    function _feeOnTotal(uint256, address) public pure override returns (uint256) {
        return 0;
    }
}
