// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseStrategy} from "@yieldnest-vault/strategy/BaseStrategy.sol";
import {LinearWithdrawalFee} from "@yieldnest-vault/module/LinearWithdrawalFee.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {QueuedRailStrategy} from "./QueuedRailStrategy.sol";
import {RailStakePositionManager} from "./RailStakePositionManager.sol";

contract StakedRailStrategy is BaseStrategy, LinearWithdrawalFee {
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace208;

    string public constant ST_RAIL_VERSION = "0.1.0";
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    RailStakePositionManager public positionManager;
    QueuedRailStrategy public queuedRail;

    // Appended storage: historical supply supports allocation at RAILGUN interval boundaries.
    Checkpoints.Trace208 private supplyHistory;

    /// @notice Supply strictly before a timestamp, matching RAILGUN's interval-start snapshot.
    /// @dev History begins with the first checkpoint after this implementation is installed.
    function totalSupplyBefore(uint256 timestamp) external view returns (uint256) {
        if (timestamp == 0 || timestamp > block.timestamp) revert InvalidSnapshotTime();
        return supplyHistory.upperLookupRecent(SafeCast.toUint48(timestamp - 1));
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from == address(0) || to == address(0)) {
            checkpointTotalSupply();
        }
    }

    /// @notice Starts supply history for an upgraded vault without requiring a deposit or exit.
    function checkpointTotalSupply() public {
        supplyHistory.push(SafeCast.toUint48(block.timestamp), SafeCast.toUint208(totalSupply()));
    }

    error InvalidSnapshotTime();

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

    //// FEES ////

    function _feeOnRaw(uint256 amount, address user) public view override returns (uint256) {
        return __feeOnRaw(amount, user);
    }

    function _feeOnTotal(uint256 amount, address user) public view override returns (uint256) {
        return __feeOnTotal(amount, user);
    }

    /// @notice Fee scale is 1e8 = 100%; 10_000 = 1 basis point.
    function setBaseWithdrawalFee(uint64 fee) external onlyRole(FEE_MANAGER_ROLE) {
        _setBaseWithdrawalFee(fee);
    }
}
