// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StakedRailStrategy} from "../StakedRailStrategy.sol";
import {RailStakePositionManager} from "../railgun/RailStakePositionManager.sol";
import {WithdrawalRequest} from "@yieldnest-vault-withdrawals/WithdrawalRequest.sol";

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
        idleRail = IERC20(strategy.asset()).balanceOf(address(strategy));
        activePrincipal = manager.activePrincipal();
        queuedPrincipal = manager.queuedPrincipal();
        totalAssets_ = strategy.totalBaseAssets();
    }

    function requestStatus(WithdrawalRequest request, uint256 requestId)
        external
        view
        returns (RailRequestStatus)
    {
        WithdrawalRequest.Request memory withdrawal = request.requests(requestId);
        if (withdrawal.amountLocked != 0) return RailRequestStatus.QUEUED;
        for (uint256 i = 0; i < withdrawal.assetsRedeemed.length; i++) {
            if (withdrawal.assetsRedeemed[i] != address(0)) return RailRequestStatus.CLAIMABLE;
        }
        return RailRequestStatus.PENDING;
    }
}
