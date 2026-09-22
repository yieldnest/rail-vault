// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WithdrawalRequest} from "@yieldnest-vault-withdrawals/WithdrawalRequest.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Permissionless FIFO settlement into the vault's base asset.
/// @dev Requires a withdrawer with matching conversion rules and liquidity held directly in the vault.
contract SingleAssetFIFOResolver {
    IERC4626 public immutable vault;
    WithdrawalRequest public immutable withdrawalRequest;

    uint256 public nextRequestToResolve;

    event RequestResolved(uint256 indexed requestId, uint256 assetAmount);
    error IncompleteRedemption(uint256 requestId, uint256 remainingShares);

    constructor(IERC4626 vaultAddress, WithdrawalRequest withdrawalRequestAddress) {
        vault = vaultAddress;
        withdrawalRequest = withdrawalRequestAddress;
    }

    function resolveRequests(uint256 maxRequests) external returns (uint256 resolved) {
        address asset = vault.asset();
        uint256 processed;
        while (processed < maxRequests && nextRequestToResolve < withdrawalRequest.nextRequestId()) {
            processed++;
            uint256 requestId = nextRequestToResolve;
            // Withdrawal request ids are monotonically increasing so this situation only exists
            // if the request was resolved by another resolver and deleted.
            if (!withdrawalRequest.requestExists(requestId)) {
                nextRequestToResolve++;
                continue;
            }

            WithdrawalRequest.Request memory request = withdrawalRequest.requests(requestId);
            uint256 shares = request.amountLocked;
            if (shares == 0) {
                nextRequestToResolve++;
                continue;
            }
            uint256 fullAmount = vault.previewRedeem(shares);
            uint256 available = IERC20(asset).balanceOf(address(vault));
            uint256 assetAmount = available < fullAmount ? available : fullAmount;
            if (assetAmount == 0) break;

            uint256 burned = withdrawalRequest.resolveWithdrawalRequest(requestId, asset, assetAmount);
            uint256 remaining = shares - burned;
            // A full settlement must consume the exact locked shares, never skip rounding dust.
            // TODO: Handle rounding residuals, including zero-value shares, without blocking the FIFO queue.
            if (assetAmount == fullAmount && remaining != 0) revert IncompleteRedemption(requestId, remaining);
            emit RequestResolved(requestId, assetAmount);
            if (remaining != 0) break;
            nextRequestToResolve++;
            resolved++;
        }
    }
}
