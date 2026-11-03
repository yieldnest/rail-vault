// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {QueuedRailStrategy} from "../core/QueuedRailStrategy.sol";
import {RailStakePositionManager} from "../core/RailStakePositionManager.sol";

contract QueuedRailProcessor {
    QueuedRailStrategy public immutable qRail;
    RailStakePositionManager public immutable positionManager;

    constructor(QueuedRailStrategy qRailAddress, RailStakePositionManager positionManagerAddress) {
        qRail = qRailAddress;
        positionManager = positionManagerAddress;
    }

    /// @notice Anyone may claim matured positions; all proceeds go to qRail.
    function claimMaturedPositions(uint256[] calldata stakeIds) external returns (uint256) {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(positionManager);
        data[0] = abi.encodeCall(RailStakePositionManager.claimMaturedPositions, (stakeIds, address(qRail)));
        bytes[] memory results = qRail.processor(targets, values, data);
        return abi.decode(results[0], (uint256));
    }
}
