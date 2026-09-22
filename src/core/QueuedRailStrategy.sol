// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseStrategy} from "@yieldnest-vault/strategy/BaseStrategy.sol";

contract QueuedRailStrategy is BaseStrategy {
    string public constant Q_RAIL_VERSION = "0.1.0";

    function initialize(address admin, uint8 decimals_) external initializer {
        _initialize(admin, "Queued RAIL", "qRAIL", decimals_, false, false, true, 0);
    }

    function _feeOnRaw(uint256, address) public pure override returns (uint256) {
        return 0;
    }

    function _feeOnTotal(uint256, address) public pure override returns (uint256) {
        return 0;
    }
}
