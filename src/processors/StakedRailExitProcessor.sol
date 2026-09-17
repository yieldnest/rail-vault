// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StakedRailStrategy} from "../StakedRailStrategy.sol";
import {QueuedRailStrategy} from "../QueuedRailStrategy.sol";
import {QueuedRailSharesHook} from "./QueuedRailSharesHook.sol";
import {RailStakePositionManager} from "../railgun/RailStakePositionManager.sol";

contract StakedRailExitProcessor {
    StakedRailStrategy public immutable stRail;
    QueuedRailStrategy public immutable qRail;
    QueuedRailSharesHook public immutable qRailSharesHook;
    RailStakePositionManager public immutable positionManager;

    constructor(
        StakedRailStrategy stRailAddress,
        QueuedRailStrategy qRailAddress,
        QueuedRailSharesHook qRailSharesHookAddress,
        RailStakePositionManager positionManagerAddress
    ) {
        stRail = stRailAddress;
        qRail = qRailAddress;
        qRailSharesHook = qRailSharesHookAddress;
        positionManager = positionManagerAddress;
    }

    function exitToQueuedRail(uint256 shares, address receiver, uint256 maxPositions) external returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();

        assets = stRail.previewRedeemAsset(address(qRail), shares);
        _fillQueuedRail(assets, maxPositions);
        assets = stRail.redeemAsset(address(qRail), shares, receiver, msg.sender);
    }

    function _fillQueuedRail(uint256 requiredAssets, uint256 maxPositions) internal {
        uint256 available = IERC20(address(qRail)).balanceOf(address(stRail));
        if (available >= requiredAssets) return;

        uint256 needed = requiredAssets - available;
        uint256 queued;
        uint256 positionsQueued;
        uint256[] memory activeStakeIds = positionManager.activeStakeIdsList();
        for (uint256 i = 0; i < activeStakeIds.length && positionsQueued < maxPositions; i++) {
            uint256 queuedPrincipal = positionManager.queuePosition(activeStakeIds[i]);
            _mintQueuedRailToStrategy(queuedPrincipal);
            queued += queuedPrincipal;
            positionsQueued++;
            if (queued >= needed) return;
        }

        revert InsufficientQueuedRail(requiredAssets, available + queued);
    }

    function _mintQueuedRailToStrategy(uint256 amount) internal {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(qRailSharesHook);
        data[0] = abi.encodeCall(QueuedRailSharesHook.mintQueuedRail, (address(stRail), amount));
        qRail.processor(targets, values, data);
    }

    error ZeroAddress();
    error ZeroShares();
    error InsufficientQueuedRail(uint256 required, uint256 available);
}
