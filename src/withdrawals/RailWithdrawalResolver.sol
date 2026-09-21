// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WithdrawalRequest} from "@yieldnest-vault-withdrawals/WithdrawalRequest.sol";

import {QueuedRailStrategy} from "../QueuedRailStrategy.sol";
import {RailStakePositionManager} from "../railgun/RailStakePositionManager.sol";

contract RailWithdrawalResolver is AccessControl {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    QueuedRailStrategy public immutable qRail;
    RailStakePositionManager public immutable positionManager;
    WithdrawalRequest public immutable withdrawalRequest;

    uint256 public nextRequestToResolve;

    event RequestResolved(uint256 indexed requestId, uint256 railAmount);

    constructor(
        address admin,
        QueuedRailStrategy qRailAddress,
        WithdrawalRequest withdrawalRequestAddress
    ) {
        qRail = qRailAddress;
        positionManager = qRailAddress.positionManager();
        withdrawalRequest = withdrawalRequestAddress;
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

    function resolveRequests(uint256 maxRequests) external onlyRole(KEEPER_ROLE) returns (uint256 resolved) {
        address rail = qRail.asset();
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
            if (IERC20(rail).balanceOf(address(qRail)) < railAmount) break;

            withdrawalRequest.resolveWithdrawalRequest(requestId, rail, railAmount);
            nextRequestToResolve++;
            resolved++;
            emit RequestResolved(requestId, railAmount);
        }
    }
}
