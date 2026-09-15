// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StakedRailStrategy} from "../StakedRailStrategy.sol";
import {RailStakePositionManager} from "../railgun/RailStakePositionManager.sol";
import {RailWithdrawalRequest} from "./RailWithdrawalRequest.sol";
import {RailWithdrawer} from "./RailWithdrawer.sol";

contract RailWithdrawalResolver is AccessControl {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    StakedRailStrategy public immutable stRail;
    RailStakePositionManager public immutable positionManager;
    RailWithdrawalRequest public immutable withdrawalRequest;
    RailWithdrawer public immutable withdrawer;

    uint256 public nextRequestToAllocate = 1;
    uint256 public nextRequestToResolve = 1;

    event RequestAllocated(uint256 indexed requestId, uint256 shares, uint256 railEntitlement);
    event RequestResolved(uint256 indexed requestId, uint256 railAmount);

    constructor(
        address admin,
        StakedRailStrategy stRail_,
        RailStakePositionManager positionManager_,
        RailWithdrawalRequest withdrawalRequest_,
        RailWithdrawer withdrawer_
    ) {
        stRail = stRail_;
        positionManager = positionManager_;
        withdrawalRequest = withdrawalRequest_;
        withdrawer = withdrawer_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function allocateRequests(uint256 maxRequests) external onlyRole(KEEPER_ROLE) returns (uint256 allocated) {
        while (allocated < maxRequests && nextRequestToAllocate < withdrawalRequest.nextRequestId()) {
            uint256 requestId = nextRequestToAllocate;
            if (!withdrawalRequest.isPending(requestId)) {
                nextRequestToAllocate++;
                continue;
            }

            (uint256 shares,,,,) = withdrawalRequest.requests(requestId);
            uint256 railEntitlement = stRail.previewRedeem(shares);
            if (withdrawer.unreservedQRAIL() < railEntitlement) break;

            withdrawer.reserve(requestId, railEntitlement);
            withdrawalRequest.markQueued(requestId, railEntitlement);
            nextRequestToAllocate++;
            allocated++;
            emit RequestAllocated(requestId, shares, railEntitlement);
        }
    }

    function claimMaturedPositions(uint256[] calldata stakeIds) external onlyRole(KEEPER_ROLE) returns (uint256) {
        return positionManager.claimMaturedPositions(stakeIds, address(withdrawer));
    }

    function resolveRequests(uint256 maxRequests) external onlyRole(KEEPER_ROLE) returns (uint256 resolved) {
        while (resolved < maxRequests && nextRequestToResolve < withdrawalRequest.nextRequestId()) {
            uint256 requestId = nextRequestToResolve;
            if (!withdrawalRequest.isQueued(requestId)) {
                nextRequestToResolve++;
                continue;
            }

            (, uint256 railEntitlement,, address bag,) = withdrawalRequest.requests(requestId);
            if (railEntitlement == 0) revert EmptyEntitlement();

            withdrawer.settle(requestId, bag, railEntitlement);
            withdrawalRequest.markResolved(requestId, railEntitlement);
            nextRequestToResolve++;
            resolved++;
            emit RequestResolved(requestId, railEntitlement);
        }
    }

    function rebalanceExits(uint256 maxPositions) external onlyRole(KEEPER_ROLE) returns (uint256 queued) {
        uint256 deficit = unstakingDeficit();
        if (deficit == 0) return 0;

        uint256[] memory activeStakeIds = positionManager.activeStakeIdsList();
        uint256 queuedAmount;
        for (uint256 i = 0; i < activeStakeIds.length && queued < maxPositions; i++) {
            queuedAmount += positionManager.queuePosition(activeStakeIds[i]);
            queued++;
            if (queuedAmount >= deficit) break;
        }
    }

    function unstakingDeficit() public view returns (uint256 deficit) {
        uint256 demand;
        uint256 nextRequestId = withdrawalRequest.nextRequestId();
        for (uint256 requestId = nextRequestToAllocate; requestId < nextRequestId; requestId++) {
            if (!withdrawalRequest.isPending(requestId)) continue;
            (uint256 shares,,,,) = withdrawalRequest.requests(requestId);
            demand += stRail.previewRedeem(shares);
        }

        uint256 available = withdrawer.unreservedQRAIL() + IERC20(withdrawer.rail()).balanceOf(address(withdrawer));
        if (demand > available) {
            deficit = demand - available;
        }
    }

    error EmptyEntitlement();
}
