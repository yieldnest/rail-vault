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
        StakedRailStrategy stRailAddress,
        RailStakePositionManager positionManagerAddress,
        uint256 stakeChunkSizeValue,
        uint256 minimumStakeAmountValue,
        uint256 targetIdleRailValue,
        uint256 maxActivePositionsValue
    ) {
        stRail = stRailAddress;
        positionManager = positionManagerAddress;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_MANAGER_ROLE, admin);
        _setStakingConfig(stakeChunkSizeValue, minimumStakeAmountValue, targetIdleRailValue, maxActivePositionsValue);
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
        uint256 stakeChunkSizeValue,
        uint256 minimumStakeAmountValue,
        uint256 targetIdleRailValue,
        uint256 maxActivePositionsValue
    ) external onlyRole(CONFIG_MANAGER_ROLE) {
        _setStakingConfig(stakeChunkSizeValue, minimumStakeAmountValue, targetIdleRailValue, maxActivePositionsValue);
    }

    function _setStakingConfig(
        uint256 stakeChunkSizeValue,
        uint256 minimumStakeAmountValue,
        uint256 targetIdleRailValue,
        uint256 maxActivePositionsValue
    ) internal {
        if (
            stakeChunkSizeValue == 0 || minimumStakeAmountValue == 0 || minimumStakeAmountValue > stakeChunkSizeValue
        ) {
            revert InvalidStakingConfig();
        }
        stakeChunkSize = stakeChunkSizeValue;
        minimumStakeAmount = minimumStakeAmountValue;
        targetIdleRail = targetIdleRailValue;
        maxActivePositions = maxActivePositionsValue;
        emit StakingConfigSet(stakeChunkSizeValue, minimumStakeAmountValue, targetIdleRailValue, maxActivePositionsValue);
    }

    error InvalidStakingConfig();
}
