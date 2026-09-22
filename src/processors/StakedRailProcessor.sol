// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {QueuedRailStrategy} from "../core/QueuedRailStrategy.sol";
import {StakedRailStrategy} from "../core/StakedRailStrategy.sol";
import {RailStakePositionManager} from "../core/RailStakePositionManager.sol";

contract StakedRailProcessor is AccessControl {
    bytes32 public constant CONFIG_MANAGER_ROLE = keccak256("CONFIG_MANAGER_ROLE");

    StakedRailStrategy public immutable stRail;
    RailStakePositionManager public immutable positionManager;
    QueuedRailStrategy public immutable qRail;

    uint256 public stakeChunkSize;
    event StakeChunkSizeSet(uint256 stakeChunkSize);

    constructor(address admin, StakedRailStrategy stRailAddress, uint256 stakeChunkSizeValue) {
        stRail = stRailAddress;
        qRail = stRailAddress.queuedRail();
        positionManager = stRailAddress.positionManager();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_MANAGER_ROLE, admin);
        _setStakeChunkSize(stakeChunkSizeValue);
    }

    //// STAKING ////

    function rebalanceStaking(uint256 maxOperations) external returns (uint256 operations) {
        IERC20 rail = IERC20(stRail.asset());
        uint256 amount = stakeChunkSize;
        while (operations < maxOperations) {
            if (rail.balanceOf(address(stRail)) < amount) break;

            address[] memory targets = new address[](2);
            uint256[] memory values = new uint256[](2);
            bytes[] memory data = new bytes[](2);

            targets[0] = address(rail);
            data[0] = abi.encodeCall(IERC20.approve, (address(positionManager), amount));
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

    //// EXITING ////

    function exitToQueuedRail(uint256 shares, address receiver, uint256 maxPositions)
        external
        returns (uint256 assets)
    {
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
        while (positionManager.activePositionCount() != 0 && positionsQueued < maxPositions) {
            uint256 queuedPrincipal = _queuePosition();
            queued += queuedPrincipal;
            positionsQueued++;
            if (queued >= needed) return;
        }

        revert InsufficientQueuedRail(requiredAssets, available + queued);
    }

    function _queuePosition() internal returns (uint256) {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(stRail);
        data[0] = abi.encodeCall(StakedRailStrategy.queuePosition, ());
        bytes[] memory results = stRail.processor(targets, values, data);
        return abi.decode(results[0], (uint256));
    }

    error ZeroAddress();
    error InvalidStakeChunkSize();
    error ZeroShares();
    error InsufficientQueuedRail(uint256 required, uint256 available);
}
