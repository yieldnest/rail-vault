// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata as IERC20} from "@yieldnest-vault/Common.sol";
import {BaseStrategy} from "@yieldnest-vault/strategy/BaseStrategy.sol";
import {VaultLib} from "@yieldnest-vault/library/VaultLib.sol";

import {RailProvider} from "./RailProvider.sol";
import {RailStakePositionManager} from "./railgun/RailStakePositionManager.sol";

contract StakedRailStrategy is BaseStrategy {
    string public constant ST_RAIL_VERSION = "0.1.0";

    RailStakePositionManager public positionManager;

    event PositionManagerSet(address indexed positionManager);

    function initialize(address admin, address rail, RailStakePositionManager positionManager_) external initializer {
        _initialize(admin, "Staked RAIL", "stRAIL", IERC20(rail).decimals(), true, false, true, 0);
        _addAsset(rail, IERC20(rail).decimals(), true);
        _setAssetWithdrawable(rail, false);
        VaultLib.setProvider(address(new RailProvider(rail)));

        positionManager = positionManager_;
        emit PositionManagerSet(address(positionManager_));
    }

    function _feeOnRaw(uint256, address) public pure override returns (uint256) {
        return 0;
    }

    function _feeOnTotal(uint256, address) public pure override returns (uint256) {
        return 0;
    }

    function totalBaseAssets() public view override returns (uint256) {
        return computeTotalAssets();
    }

    function computeTotalAssets() public view override returns (uint256 totalBaseBalance) {
        totalBaseBalance = IERC20(asset()).balanceOf(address(this));
        if (address(positionManager) != address(0)) {
            totalBaseBalance += positionManager.activePrincipal();
            totalBaseBalance += positionManager.queuedPrincipal();
        }
    }

    function processorBurnShares(address owner, uint256 shares) external {
        if (msg.sender != address(this)) revert OnlyProcessorSelfCall();
        _burn(owner, shares);
    }

    error OnlyProcessorSelfCall();
}
