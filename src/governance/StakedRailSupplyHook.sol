// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@yieldnest-vault/interface/IHooks.sol";
import {IVault} from "@yieldnest-vault/interface/IVault.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Total-supply history using the vault's existing hook callbacks.
/// @dev Supports direct installation or calls through the vault's configured hook (e.g. MetaHooks).
/// Run after any other hook that changes supply. No owner, mutable config, or share-minting calls.
/// Governance must never detach and reinstall this hook: the vault exposes no installation nonce
/// and an unobserved removal/reinstallation cannot be reliably detected onchain.
contract StakedRailSupplyHook is IHooks {
    using Checkpoints for Checkpoints.Trace208;

    IVault public immutable VAULT;
    uint256 public historyStartedAt;
    Checkpoints.Trace208 private supplyHistory;

    error InvalidVault();
    error HistoryNotStarted();
    error InvalidSnapshotTime();
    error ImmutableConfig();

    constructor(IVault vault_) {
        if (address(vault_).code.length == 0) revert InvalidVault();
        VAULT = vault_;
    }

    modifier onlyVaultOrHook() {
        if (msg.sender != address(VAULT) && msg.sender != address(VAULT.hooks())) revert CallerNotVault();
        _;
    }

    function name() external pure returns (string memory) {
        return "StakedRailSupplyHook";
    }

    function getConfig() external pure returns (Config memory config) {
        config = Config(false, true, false, true, false, true, false, true, false, true);
    }

    function setConfig(Config memory) external pure {
        revert ImmutableConfig();
    }

    /// @notice Seed existing supply during setup. Later calls record current supply but cannot reconstruct missed history.
    function checkpoint() external {
        if (historyStartedAt == 0) {
            historyStartedAt = block.timestamp;
        }
        _record();
    }

    function totalSupplyBefore(uint256 timestamp) external view returns (uint256) {
        if (timestamp == 0 || timestamp > block.timestamp) revert InvalidSnapshotTime();
        if (timestamp <= historyStartedAt) return 0;
        return supplyHistory.upperLookupRecent(SafeCast.toUint48(timestamp - 1));
    }

    function _record() private {
        if (historyStartedAt == 0) revert HistoryNotStarted();
        supplyHistory.push(SafeCast.toUint48(block.timestamp), SafeCast.toUint208(VAULT.totalSupply()));
    }

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
