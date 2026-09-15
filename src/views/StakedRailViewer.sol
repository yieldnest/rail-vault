// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakedRailStrategy} from "../StakedRailStrategy.sol";
import {RailStakePositionManager} from "../railgun/RailStakePositionManager.sol";
import {RailWithdrawalRequest} from "../withdrawals/RailWithdrawalRequest.sol";

contract StakedRailViewer {
    enum RailRequestStatus {
        PENDING,
        QUEUED,
        CLAIMABLE,
        CLAIMED
    }

    function strategyAssets(StakedRailStrategy strategy)
        external
        view
        returns (uint256 idleRail, uint256 activePrincipal, uint256 queuedPrincipal, uint256 totalAssets_)
    {
        RailStakePositionManager manager = strategy.positionManager();
        idleRail = strategy.totalBaseAssets() - manager.activePrincipal() - manager.queuedPrincipal();
        activePrincipal = manager.activePrincipal();
        queuedPrincipal = manager.queuedPrincipal();
        totalAssets_ = strategy.totalBaseAssets();
    }

    function requestStatus(RailWithdrawalRequest request, uint256 requestId)
        external
        view
        returns (RailRequestStatus)
    {
        (,,,, RailWithdrawalRequest.RequestStatus status) = request.requests(requestId);
        if (status == RailWithdrawalRequest.RequestStatus.PENDING) return RailRequestStatus.PENDING;
        if (status == RailWithdrawalRequest.RequestStatus.QUEUED) return RailRequestStatus.QUEUED;
        if (status == RailWithdrawalRequest.RequestStatus.CLAIMABLE) return RailRequestStatus.CLAIMABLE;
        return RailRequestStatus.CLAIMED;
    }
}
