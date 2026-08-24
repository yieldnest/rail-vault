// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata as IERC20, Math} from "@yieldnest-vault/src/Common.sol";
import {Vault} from "@yieldnest-vault/src/Vault.sol";
import {VaultLib} from "@yieldnest-vault/src/library/VaultLib.sol";

import {RailWithdrawalNFT} from "./withdrawals/RailWithdrawalNFT.sol";

contract RAILxVault is Vault {
    string public constant RAILX_VERSION = "0.1.0";

    RailWithdrawalNFT public withdrawalNFT;

    event AsyncWithdrawalRequested(
        address indexed caller,
        address indexed owner,
        address indexed receiver,
        uint256 tokenId,
        uint256 assets,
        uint256 shares
    );

    function initialize(address admin, address rail, address provider, RailWithdrawalNFT withdrawalNFT_)
        external
        initializer
    {
        _initialize(admin, "Auto-compounding RAIL", "RAILx", IERC20(rail).decimals(), true, false, false, 0);
        _setBaseWithdrawalFee(0);
        _addAsset(rail, IERC20(rail).decimals(), true);
        VaultLib.setProvider(provider);
        withdrawalNFT = withdrawalNFT_;
    }

    function requestWithdrawal(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 tokenId, uint256 assets)
    {
        if (paused()) revert Paused();
        if (shares > balanceOf(owner)) revert ExceededMaxRedeem(owner, shares, balanceOf(owner));

        assets = previewRedeem(shares);
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        uint256 baseAssets = _convertAssetToBase(asset(), assets, Math.Rounding.Floor);
        _subTotalAssets(baseAssets);
        _burn(owner, shares);
        tokenId = withdrawalNFT.mintRequest(receiver, assets, shares);

        emit AsyncWithdrawalRequested(msg.sender, owner, receiver, tokenId, assets, shares);
    }
}
