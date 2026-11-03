// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IHooks} from "@yieldnest-vault/interface/IHooks.sol";
import {IVault} from "@yieldnest-vault/interface/IVault.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @notice Total-supply history using the vault's existing hook callbacks.
 * @dev Supports direct installation or calls through the vault's configured hook (e.g. MetaHooks).
 * Run after any other hook that changes supply. Upgrade authority belongs to the proxy admin.
 * Checkpoint history is kept in regular contract storage across compatible implementation upgrades.
 * Governance must never detach and reinstall this hook: the vault exposes no installation nonce
 * and an unobserved removal/reinstallation cannot be reliably detected onchain.
 */
contract StakedRailSupplyHook is IHooks, Initializable {
    using Checkpoints for Checkpoints.Trace208;

    //// STORAGE ////

    // Preserve declaration order and types across upgrades; append new state after existing fields.
    IVault public override VAULT;
    uint256 public historyStartedAt;
    Checkpoints.Trace208 private _supplyHistory;

    //// ERRORS ////

    error InvalidVault();
    error HistoryNotStarted();
    error InvalidSnapshotTime();
    error ImmutableConfig();

    //// INITIALIZATION ////

    constructor() {
        _disableInitializers();
    }

    function initialize(IVault vault_) external initializer {
        if (address(vault_) == address(0)) revert InvalidVault();

        VAULT = vault_;
    }

    //// MODIFIERS ////

    modifier onlyVaultOrHook() {
        IVault vault = VAULT;
        if (msg.sender != address(vault) && msg.sender != address(vault.hooks())) revert CallerNotVault();
        _;
    }

    //// CONFIGURATION ////

    function name() external pure returns (string memory) {
        return "StakedRailSupplyHook";
    }

    function getConfig() external pure returns (Config memory config) {
        config = Config(false, true, false, true, false, true, false, true, false, true);
    }

    function setConfig(Config memory) external pure {
        revert ImmutableConfig();
    }

    //// CHECKPOINTS ////

    /**
     * @notice Seed existing supply during setup. Later calls record current supply but cannot reconstruct missed history.
     */
    function checkpoint() external {
        if (historyStartedAt == 0) {
            historyStartedAt = block.timestamp;
        }
        _record();
    }

    function totalSupplyBefore(uint256 timestamp) external view returns (uint256) {
        if (timestamp == 0 || timestamp > block.timestamp) revert InvalidSnapshotTime();

        if (timestamp <= historyStartedAt) return 0;
        return _supplyHistory.upperLookupRecent(SafeCast.toUint48(timestamp - 1));
    }

    function _record() private {
        if (historyStartedAt == 0) revert HistoryNotStarted();

        _supplyHistory.push(SafeCast.toUint48(block.timestamp), SafeCast.toUint208(VAULT.totalSupply()));
    }

    //// HOOK CALLBACKS ////

    function beforeDeposit(DepositParams memory) external view onlyVaultOrHook {}

    function afterDeposit(DepositParams memory) external onlyVaultOrHook {
        _record();
    }

    function beforeMint(MintParams memory) external view onlyVaultOrHook {}

    function afterMint(MintParams memory) external onlyVaultOrHook {
        _record();
    }

    function beforeWithdraw(WithdrawParams memory) external view onlyVaultOrHook {}

    function afterWithdraw(WithdrawParams memory) external onlyVaultOrHook {
        _record();
    }

    function beforeRedeem(RedeemParams memory) external view onlyVaultOrHook {}

    function afterRedeem(RedeemParams memory) external onlyVaultOrHook {
        _record();
    }

    function beforeProcessAccounting(BeforeProcessAccountingParams memory) external view onlyVaultOrHook {}

    function afterProcessAccounting(AfterProcessAccountingParams memory) external onlyVaultOrHook {
        _record();
    }
}
