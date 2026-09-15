// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata as IERC20, SafeERC20} from "@yieldnest-vault/src/Common.sol";
import {BaseStrategy} from "@yieldnest-vault/src/strategy/BaseStrategy.sol";
import {VaultLib} from "@yieldnest-vault/src/library/VaultLib.sol";

import {RailProvider} from "./RailProvider.sol";
import {RailStakePositionManager} from "./railgun/RailStakePositionManager.sol";

contract StakedRailStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    string public constant ST_RAIL_VERSION = "0.1.0";

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant CONFIG_MANAGER_ROLE = keccak256("CONFIG_MANAGER_ROLE");
    bytes32 public constant WITHDRAWAL_REQUEST_ROLE = keccak256("WITHDRAWAL_REQUEST_ROLE");

    RailStakePositionManager public positionManager;
    uint256 public stakeChunkSize;
    uint256 public minimumStakeAmount;
    uint256 public targetIdleRail;
    uint256 public maxActivePositions;

    event PositionManagerSet(address indexed positionManager);
    event StakingConfigSet(
        uint256 stakeChunkSize, uint256 minimumStakeAmount, uint256 targetIdleRail, uint256 maxActivePositions
    );

    function initialize(
        address admin,
        address rail,
        RailStakePositionManager positionManager_,
        uint256 stakeChunkSize_,
        uint256 minimumStakeAmount_,
        uint256 targetIdleRail_,
        uint256 maxActivePositions_
    ) external initializer {
        _initialize(admin, "Staked RAIL", "stRAIL", IERC20(rail).decimals(), true, false, true, 0);
        _addAsset(rail, IERC20(rail).decimals(), true);
        _setAssetWithdrawable(rail, false);
        VaultLib.setProvider(address(new RailProvider(rail)));

        positionManager = positionManager_;
        _setStakingConfig(stakeChunkSize_, minimumStakeAmount_, targetIdleRail_, maxActivePositions_);

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

    function rebalanceStaking(uint256 maxOperations) external onlyRole(KEEPER_ROLE) returns (uint256 operations) {
        IERC20 rail = IERC20(asset());
        while (operations < maxOperations) {
            uint256 idle = rail.balanceOf(address(this));
            if (idle <= targetIdleRail || idle - targetIdleRail < minimumStakeAmount) break;
            if (positionManager.activePositionCount() >= maxActivePositions) break;

            uint256 amount = idle - targetIdleRail;
            if (amount > stakeChunkSize) amount = stakeChunkSize;
            if (amount < minimumStakeAmount) break;

            rail.safeTransfer(address(positionManager), amount);
            positionManager.createPosition(amount);
            operations++;
        }
    }

    function burnLockedShares(address owner, uint256 shares) external onlyRole(WITHDRAWAL_REQUEST_ROLE) {
        _burn(owner, shares);
    }

    function setStakingConfig(
        uint256 stakeChunkSize_,
        uint256 minimumStakeAmount_,
        uint256 targetIdleRail_,
        uint256 maxActivePositions_
    ) external onlyRole(CONFIG_MANAGER_ROLE) {
        _setStakingConfig(stakeChunkSize_, minimumStakeAmount_, targetIdleRail_, maxActivePositions_);
    }

    function _setStakingConfig(
        uint256 stakeChunkSize_,
        uint256 minimumStakeAmount_,
        uint256 targetIdleRail_,
        uint256 maxActivePositions_
    ) internal {
        if (stakeChunkSize_ == 0 || minimumStakeAmount_ == 0 || minimumStakeAmount_ > stakeChunkSize_) {
            revert InvalidStakingConfig();
        }
        stakeChunkSize = stakeChunkSize_;
        minimumStakeAmount = minimumStakeAmount_;
        targetIdleRail = targetIdleRail_;
        maxActivePositions = maxActivePositions_;
        emit StakingConfigSet(stakeChunkSize_, minimumStakeAmount_, targetIdleRail_, maxActivePositions_);
    }

    error InvalidStakingConfig();
}
