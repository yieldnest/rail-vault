// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata as IERC20} from "@yieldnest-vault/Common.sol";
import {BaseStrategy} from "@yieldnest-vault/strategy/BaseStrategy.sol";
import {VaultLib} from "@yieldnest-vault/library/VaultLib.sol";

import {RailProvider} from "./RailProvider.sol";
import {RailStakePositionManager} from "./railgun/RailStakePositionManager.sol";

contract QueuedRailStrategy is BaseStrategy {
    RailStakePositionManager public positionManager;

    function initialize(address admin, address rail, RailStakePositionManager positionManager_) external initializer {
        _initialize(admin, "Queued RAIL", "qRAIL", IERC20(rail).decimals(), false, false, true, 0);
        _addAsset(rail, IERC20(rail).decimals(), false);
        _setAssetWithdrawable(rail, true);
        VaultLib.setProvider(address(new RailProvider(rail, address(0))));

        positionManager = positionManager_;
    }

    function computeTotalAssets() public view override returns (uint256 totalBaseBalance) {
        totalBaseBalance = IERC20(asset()).balanceOf(address(this));
        if (address(positionManager) != address(0)) {
            totalBaseBalance += positionManager.queuedPrincipal();
        }
    }

    function _feeOnRaw(uint256, address) public pure override returns (uint256) {
        return 0;
    }

    function _feeOnTotal(uint256, address) public pure override returns (uint256) {
        return 0;
    }
}
