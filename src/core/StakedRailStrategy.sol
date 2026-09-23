// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseStrategy} from "@yieldnest-vault/strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {QueuedRailStrategy} from "./QueuedRailStrategy.sol";
import {RailStakePositionManager} from "./RailStakePositionManager.sol";

contract StakedRailStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    string public constant ST_RAIL_VERSION = "0.1.0";

    RailStakePositionManager public positionManager;
    QueuedRailStrategy public queuedRail;

    event PositionManagerSet(address indexed positionManager);

    error OnlyProcessorSelfCall();
    error ZeroQueuedShares();

    function queuePosition() external returns (uint256 shares) {
        if (msg.sender != address(this)) revert OnlyProcessorSelfCall();
        uint256 principal = positionManager.queuePosition();
        IERC20 unlockedRail = IERC20(address(positionManager.unlockedRail()));
        unlockedRail.forceApprove(address(queuedRail), principal);
        shares = queuedRail.depositAsset(address(unlockedRail), principal, address(this));
        if (shares == 0) revert ZeroQueuedShares();
    }

    function initialize(
        address admin,
        string memory name,
        string memory symbol,
        uint8 decimals_,
        bool paused_,
        bool countNativeAsset_,
        bool alwaysComputeTotalAssets_,
        uint256 defaultAssetIndex_,
        RailStakePositionManager positionManagerAddress,
        QueuedRailStrategy queuedRailAddress
    ) external initializer {
        _initialize(
            admin, name, symbol, decimals_, paused_, countNativeAsset_, alwaysComputeTotalAssets_, defaultAssetIndex_
        );

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
}
