// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {QueuedRailStrategy} from "../core/QueuedRailStrategy.sol";
import {RailStakePositionManager} from "../core/RailStakePositionManager.sol";

contract QueuedRailProcessor is AccessControl {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    QueuedRailStrategy public immutable qRail;
    RailStakePositionManager public immutable positionManager;

    constructor(address admin, QueuedRailStrategy qRailAddress) {
        qRail = qRailAddress;
        positionManager = qRailAddress.positionManager();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function claimMaturedPositions(uint256[] calldata stakeIds) external onlyRole(KEEPER_ROLE) returns (uint256) {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(positionManager);
        data[0] = abi.encodeCall(RailStakePositionManager.claimMaturedPositions, (stakeIds, address(qRail)));
        bytes[] memory results = qRail.processor(targets, values, data);
        return abi.decode(results[0], (uint256));
    }
}
