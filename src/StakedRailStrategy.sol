// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata as IERC20} from "@yieldnest-vault/Common.sol";
import {BaseStrategy} from "@yieldnest-vault/strategy/BaseStrategy.sol";
import {VaultLib} from "@yieldnest-vault/library/VaultLib.sol";

import {QueuedRailStrategy} from "./QueuedRailStrategy.sol";
import {RailProvider} from "./RailProvider.sol";
import {RailStakePositionManager} from "./railgun/RailStakePositionManager.sol";

contract StakedRailStrategy is BaseStrategy {
    string public constant ST_RAIL_VERSION = "0.1.0";

    RailStakePositionManager public positionManager;
    QueuedRailStrategy public queuedRail;

    event PositionManagerSet(address indexed positionManager);

    error OnlyProcessorSelfCall();

    function queuePosition() external returns (uint256 principal) {
        if (msg.sender != address(this)) revert OnlyProcessorSelfCall();
        principal = positionManager.queuePosition();
        queuedRail.mintQueuedRail(address(this), principal);
    }

    function initialize(
        address admin,
        address rail,
        RailStakePositionManager positionManagerAddress,
        QueuedRailStrategy queuedRailAddress
    )
        external
        initializer
    {
        _initialize(admin, "Staked RAIL", "stRAIL", IERC20(rail).decimals(), true, false, true, 0);
        _addAsset(rail, IERC20(rail).decimals(), true);
        _addAsset(address(queuedRailAddress), IERC20(rail).decimals(), false);
        _setAssetWithdrawable(rail, false);
        _setAssetWithdrawable(address(queuedRailAddress), true);
        VaultLib.setProvider(address(new RailProvider(rail, address(queuedRailAddress))));

        positionManager = positionManagerAddress;
        queuedRail = queuedRailAddress;
        emit PositionManagerSet(address(positionManagerAddress));
    }

    function _feeOnRaw(uint256, address) public pure override returns (uint256) {
        return 0;
    }

    function _feeOnTotal(uint256, address) public pure override returns (uint256) {
        return 0;
    }

    function computeTotalAssets() public view override returns (uint256 totalBaseBalance) {
        totalBaseBalance = super.computeTotalAssets();
        if (address(positionManager) != address(0)) {
            totalBaseBalance += positionManager.activePrincipal();
        }
    }
}
