// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata as IERC20} from "@yieldnest-vault/Common.sol";
import {BaseStrategy} from "@yieldnest-vault/strategy/BaseStrategy.sol";
import {VaultLib} from "@yieldnest-vault/library/VaultLib.sol";

import {RailProvider} from "./RailProvider.sol";
import {RailStakePositionManager} from "./RailStakePositionManager.sol";

contract QueuedRailStrategy is BaseStrategy {
    string public constant Q_RAIL_VERSION = "0.1.0";

    RailStakePositionManager public positionManager;
    address public stakedRail;

    error OnlyStakedRail();
    error InvalidStakedRail();

    function mintQueuedRail(address receiver, uint256 shares) external {
        if (msg.sender != stakedRail) revert OnlyStakedRail();
        _mint(receiver, shares);
    }

    function initialize(
        address admin,
        address rail,
        RailStakePositionManager positionManagerAddress,
        address stakedRailAddress
    ) external initializer {
        if (stakedRailAddress == address(0)) revert InvalidStakedRail();
        stakedRail = stakedRailAddress;
        _initialize(admin, "Queued RAIL", "qRAIL", IERC20(rail).decimals(), false, false, true, 0);
        _addAsset(rail, IERC20(rail).decimals(), false);
        _setAssetWithdrawable(rail, true);
        VaultLib.setProvider(address(new RailProvider(rail, address(0))));

        positionManager = positionManagerAddress;
    }

    function computeTotalAssets() public view override returns (uint256 totalBaseBalance) {
        totalBaseBalance = super.computeTotalAssets();
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
