// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakedRailStrategy} from "../StakedRailStrategy.sol";
import {QueuedRailStrategy} from "../QueuedRailStrategy.sol";

contract StakedRailExitProcessor {
    StakedRailStrategy public immutable stRail;
    QueuedRailStrategy public immutable qRail;

    constructor(StakedRailStrategy stRail_, QueuedRailStrategy qRail_) {
        stRail = stRail_;
        qRail = qRail_;
    }

    function exitToQueuedRail(uint256 shares, address receiver) external returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();

        assets = stRail.previewRedeem(shares);

        address[] memory stRailTargets = new address[](1);
        uint256[] memory stRailValues = new uint256[](1);
        bytes[] memory stRailData = new bytes[](1);
        stRailTargets[0] = address(stRail);
        stRailData[0] = abi.encodeCall(StakedRailStrategy.processorBurnShares, (msg.sender, shares));
        stRail.processor(stRailTargets, stRailValues, stRailData);

        address[] memory qRailTargets = new address[](1);
        uint256[] memory qRailValues = new uint256[](1);
        bytes[] memory qRailData = new bytes[](1);
        qRailTargets[0] = address(qRail);
        qRailData[0] = abi.encodeCall(QueuedRailStrategy.processorMintShares, (receiver, assets));
        qRail.processor(qRailTargets, qRailValues, qRailData);
    }

    error ZeroAddress();
    error ZeroShares();
}
