// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVault} from "@yieldnest-vault/interface/IVault.sol";
import {IHooks} from "@yieldnest-vault/interface/IHooks.sol";

contract QueuedRailSharesHook is IHooks {
    IVault public immutable override VAULT;
    Config private config;

    constructor(IVault vaultAddress) {
        VAULT = vaultAddress;
    }

    function name() external pure returns (string memory) {
        return "QueuedRailSharesHook";
    }

    function setConfig(Config memory newConfig) external {
        Config memory oldConfig = config;
        config = newConfig;
        emit SetConfig(oldConfig, newConfig);
    }

    function getConfig() external view returns (Config memory) {
        return config;
    }

    function mintQueuedRail(address receiver, uint256 shares) external {
        if (msg.sender != address(VAULT)) revert CallerNotVault();
        VAULT.mintShares(receiver, shares);
    }

    function beforeDeposit(DepositParams memory) external pure {}
    function afterDeposit(DepositParams memory) external pure {}
    function beforeMint(MintParams memory) external pure {}
    function afterMint(MintParams memory) external pure {}
    function beforeRedeem(RedeemParams memory) external pure {}
    function afterRedeem(RedeemParams memory) external pure {}
    function beforeWithdraw(WithdrawParams memory) external pure {}
    function afterWithdraw(WithdrawParams memory) external pure {}
    function beforeProcessAccounting(BeforeProcessAccountingParams memory) external pure {}
    function afterProcessAccounting(AfterProcessAccountingParams memory) external pure {}
}
