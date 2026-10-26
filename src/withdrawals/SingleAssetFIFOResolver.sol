// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WithdrawalRequest} from "@yieldnest-vault-withdrawals/WithdrawalRequest.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @notice Permissionless FIFO settlement into the base asset, with residual shares sent to the Bag.
/// @dev Requires matching conversion rules, direct base-asset liquidity and vault-token transfers in the withdrawer.
contract SingleAssetFIFOResolver is Initializable {
    /// @custom:storage-location erc7201:rail.storage.SingleAssetFIFOResolver
    struct ResolverStorage {
        IERC4626 vault;
        WithdrawalRequest withdrawalRequest;
        uint256 nextRequestToResolve;
    }

    // keccak256(abi.encode(uint256(keccak256("rail.storage.SingleAssetFIFOResolver")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RESOLVER_STORAGE_LOCATION =
        0x4545b7f984776cb6537e24c52c21afd9b79e481ff408a6ffee3ab74acfe88f00;

    function _getResolverStorage() private pure returns (ResolverStorage storage $) {
        assembly {
            $.slot := RESOLVER_STORAGE_LOCATION
        }
    }

    function vault() public view returns (IERC4626) {
        return _getResolverStorage().vault;
    }

    function withdrawalRequest() public view returns (WithdrawalRequest) {
        return _getResolverStorage().withdrawalRequest;
    }

    function nextRequestToResolve() public view returns (uint256) {
        return _getResolverStorage().nextRequestToResolve;
    }

    event RequestResolved(uint256 indexed requestId, uint256 assetAmount);
    error IncompleteRedemption(uint256 requestId, uint256 remainingShares);

    error ZeroAddress();

    constructor() {
        _disableInitializers();
    }

    function initialize(IERC4626 vaultAddress, WithdrawalRequest withdrawalRequestAddress) external initializer {
        if (address(vaultAddress) == address(0) || address(withdrawalRequestAddress) == address(0)) {
            revert ZeroAddress();
        }
        ResolverStorage storage $ = _getResolverStorage();
        $.vault = vaultAddress;
        $.withdrawalRequest = withdrawalRequestAddress;
    }

    function resolveRequests(uint256 maxRequests) external returns (uint256 resolved) {
        ResolverStorage storage $ = _getResolverStorage();
        IERC4626 vault_ = $.vault;
        WithdrawalRequest requests = $.withdrawalRequest;
        address asset = vault_.asset();
        uint256 processed;
        while (processed < maxRequests && $.nextRequestToResolve < requests.nextRequestId()) {
            processed++;
            uint256 requestId = $.nextRequestToResolve;
            // Withdrawal request ids are monotonically increasing so this situation only exists
            // if the request was resolved by another resolver and deleted.
            if (!requests.requestExists(requestId)) {
                $.nextRequestToResolve++;
                continue;
            }

            WithdrawalRequest.Request memory request = requests.requests(requestId);
            uint256 shares = request.amountLocked;
            if (shares == 0) {
                $.nextRequestToResolve++;
                continue;
            }
            uint256 fullAmount = vault_.previewRedeem(shares);
            uint256 available = IERC20(asset).balanceOf(address(vault_));
            uint256 assetAmount = available < fullAmount ? available : fullAmount;
            if (assetAmount == 0 && fullAmount != 0) break;

            uint256 burned;
            if (assetAmount != 0) {
                burned = requests.resolveWithdrawalRequest(requestId, asset, assetAmount);
            }
            uint256 remaining = shares - burned;
            // Only full settlements may release residual shares; partial fills must remain in FIFO order.
            if (assetAmount == fullAmount && remaining != 0) {
                remaining -= requests.resolveWithdrawalRequest(requestId, address(vault_), remaining);
                if (remaining != 0) revert IncompleteRedemption(requestId, remaining);
            }
            emit RequestResolved(requestId, assetAmount);
            if (remaining != 0) break;
            $.nextRequestToResolve++;
            resolved++;
        }
    }
}
