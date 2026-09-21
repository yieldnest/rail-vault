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
    event StakeChunkSizeSet(uint256 stakeChunkSize);

    constructor(
        address admin,
        StakedRailStrategy stRailAddress,
        uint256 stakeChunkSizeValue
    ) {
        stRail = stRailAddress;
        positionManager = stRailAddress.positionManager();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_MANAGER_ROLE, admin);
        _setStakeChunkSize(stakeChunkSizeValue);
    }

    function rebalanceStaking(uint256 maxOperations) external returns (uint256 operations) {
        IERC20 rail = IERC20(stRail.asset());
        uint256 amount = stakeChunkSize;
        while (operations < maxOperations) {
            if (rail.balanceOf(address(stRail)) < amount) break;

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

    function setStakeChunkSize(uint256 stakeChunkSizeValue) external onlyRole(CONFIG_MANAGER_ROLE) {
        _setStakeChunkSize(stakeChunkSizeValue);
    }

    function _setStakeChunkSize(uint256 stakeChunkSizeValue) internal {
        if (stakeChunkSizeValue == 0) revert InvalidStakeChunkSize();
        stakeChunkSize = stakeChunkSizeValue;
        emit StakeChunkSizeSet(stakeChunkSizeValue);
    }

    error InvalidStakeChunkSize();
}
