// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {StakedRailStrategy} from "../StakedRailStrategy.sol";
import {RailStakePositionManager} from "../railgun/RailStakePositionManager.sol";

contract StakedRailStakingProcessor is AccessControl {
    bytes32 public constant CONFIG_MANAGER_ROLE = keccak256("CONFIG_MANAGER_ROLE");

    StakedRailStrategy public immutable stRail;
    RailStakePositionManager public immutable positionManager;

    uint256 public stakeChunkSize;
    uint256 public minimumStakeAmount;
    uint256 public targetIdleRail;
    uint256 public maxActivePositions;

    event StakingConfigSet(
        uint256 stakeChunkSize, uint256 minimumStakeAmount, uint256 targetIdleRail, uint256 maxActivePositions
    );

    constructor(
        address admin,
        StakedRailStrategy stRail_,
        RailStakePositionManager positionManager_,
        uint256 stakeChunkSize_,
        uint256 minimumStakeAmount_,
        uint256 targetIdleRail_,
        uint256 maxActivePositions_
    ) {
        stRail = stRail_;
        positionManager = positionManager_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_MANAGER_ROLE, admin);
        _setStakingConfig(stakeChunkSize_, minimumStakeAmount_, targetIdleRail_, maxActivePositions_);
    }

    function rebalanceStaking(uint256 maxOperations) external returns (uint256 operations) {
        IERC20 rail = IERC20(stRail.asset());
        while (operations < maxOperations) {
            uint256 idle = rail.balanceOf(address(stRail));
            if (idle <= targetIdleRail || idle - targetIdleRail < minimumStakeAmount) break;
            if (positionManager.activePositionCount() >= maxActivePositions) break;

            uint256 amount = idle - targetIdleRail;
            if (amount > stakeChunkSize) amount = stakeChunkSize;
            if (amount < minimumStakeAmount) break;

            address[] memory targets = new address[](2);
            uint256[] memory values = new uint256[](2);
            bytes[] memory data = new bytes[](2);

            targets[0] = address(rail);
            data[0] = abi.encodeCall(IERC20.transfer, (address(positionManager), amount));
            targets[1] = address(positionManager);
            data[1] = abi.encodeCall(RailStakePositionManager.createPosition, (amount));

            stRail.processor(targets, values, data);
            operations++;
        }
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
