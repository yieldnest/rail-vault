// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WithdrawalRequest} from "@yieldnest-vault-withdrawals/WithdrawalRequest.sol";

import {QueuedRailStrategy} from "../QueuedRailStrategy.sol";
import {StakedRailStrategy} from "../StakedRailStrategy.sol";
import {RailStakePositionManager} from "../railgun/RailStakePositionManager.sol";
import {RailWithdrawer} from "./RailWithdrawer.sol";

contract RailWithdrawalResolver is AccessControl {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    StakedRailStrategy public immutable stRail;
    QueuedRailStrategy public immutable qRail;
    RailStakePositionManager public immutable positionManager;
    WithdrawalRequest public immutable withdrawalRequest;
    RailWithdrawer public immutable withdrawer;

    uint256 public nextRequestToResolve;

    event RequestResolved(uint256 indexed requestId, uint256 railAmount);

    constructor(
        address admin,
        StakedRailStrategy stRail_,
        QueuedRailStrategy qRail_,
        RailStakePositionManager positionManager_,
        WithdrawalRequest withdrawalRequest_,
        RailWithdrawer withdrawer_
    ) {
        stRail = stRail_;
        qRail = qRail_;
        positionManager = positionManager_;
        withdrawalRequest = withdrawalRequest_;
        withdrawer = withdrawer_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function claimMaturedPositions(uint256[] calldata stakeIds) external onlyRole(KEEPER_ROLE) returns (uint256) {
        return positionManager.claimMaturedPositions(stakeIds, address(withdrawer));
    }

    function resolveRequests(uint256 maxRequests) external onlyRole(KEEPER_ROLE) returns (uint256 resolved) {
        while (resolved < maxRequests && nextRequestToResolve < withdrawalRequest.nextRequestId()) {
            uint256 requestId = nextRequestToResolve;
            if (!withdrawalRequest.requestExists(requestId)) {
                nextRequestToResolve++;
                continue;
            }

            WithdrawalRequest.Request memory request = withdrawalRequest.requests(requestId);
            uint256 railAmount = request.amountLocked;
            if (railAmount == 0) {
                nextRequestToResolve++;
                continue;
            }
            if (IERC20(withdrawer.rail()).balanceOf(address(withdrawer)) < railAmount) break;

            withdrawalRequest.resolveWithdrawalRequest(requestId, address(withdrawer.rail()), railAmount);
            nextRequestToResolve++;
            resolved++;
            emit RequestResolved(requestId, railAmount);
        }
    }

    function rebalanceExits(uint256 maxPositions) external onlyRole(KEEPER_ROLE) returns (uint256 queued) {
        uint256 deficit = unstakingDeficit();
        if (deficit == 0) return 0;

        uint256[] memory activeStakeIds = positionManager.activeStakeIdsList();
        uint256 queuedAmount;
        for (uint256 i = 0; i < activeStakeIds.length && queued < maxPositions; i++) {
            uint256 queuedPrincipal = positionManager.queuePosition(activeStakeIds[i]);
            _mintQueuedRailToStrategy(queuedPrincipal);
            queuedAmount += queuedPrincipal;
            queued++;
            if (queuedAmount >= deficit) break;
        }
    }

    function unstakingDeficit() public view returns (uint256 deficit) {
        uint256 demand;
        uint256 nextRequestId = withdrawalRequest.nextRequestId();
        for (uint256 requestId = nextRequestToResolve; requestId < nextRequestId; requestId++) {
            if (!withdrawalRequest.requestExists(requestId)) continue;
            WithdrawalRequest.Request memory request = withdrawalRequest.requests(requestId);
            demand += request.amountLocked;
        }

        uint256 available = IERC20(withdrawer.rail()).balanceOf(address(withdrawer)) + positionManager.queuedPrincipal();
        if (demand > available) {
            deficit = demand - available;
        }
    }

    function _mintQueuedRailToStrategy(uint256 amount) internal {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(qRail);
        data[0] = abi.encodeCall(QueuedRailStrategy.processorMintShares, (address(stRail), amount));
        qRail.processor(targets, values, data);
    }
}
