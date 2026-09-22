// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata as IERC20} from "@yieldnest-vault/Common.sol";
import {BaseStrategy} from "@yieldnest-vault/strategy/BaseStrategy.sol";
import {VaultLib} from "@yieldnest-vault/library/VaultLib.sol";

import {RailProvider} from "./RailProvider.sol";
import {RailStakePositionManager} from "./RailStakePositionManager.sol";

contract QueuedRailStrategy is BaseStrategy {
    string public constant Q_RAIL_VERSION = "0.1.0";

    function initialize(address admin, address rail, RailStakePositionManager positionManagerAddress)
        external
        initializer
    {
        _initialize(admin, "Queued RAIL", "qRAIL", IERC20(rail).decimals(), false, false, true, 0);
        _setHasAllocator(true);
        _addAsset(rail, IERC20(rail).decimals(), false);
        _addAsset(address(positionManagerAddress.unlockedRail()), IERC20(rail).decimals(), true);
        _setAssetWithdrawable(rail, true);
        VaultLib.setProvider(
            address(new RailProvider(rail, address(0), address(positionManagerAddress.unlockedRail()), address(0)))
        );
    }

    function _feeOnRaw(uint256, address) public pure override returns (uint256) {
        return 0;
    }

    function _feeOnTotal(uint256, address) public pure override returns (uint256) {
        return 0;
    }
}
