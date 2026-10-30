// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@yieldnest-vault/interface/IHooks.sol";
import {IVault} from "@yieldnest-vault/interface/IVault.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Total-supply history using the vault's existing hook callbacks.
/// @dev Install directly, not through MetaHooks. No owner, mutable config, or share-minting calls.
/// Governance must never detach and reinstall this hook: the vault exposes no installation nonce
/// and an unobserved removal/reinstallation cannot be reliably detected onchain.
contract StakedRailSupplyHook is IHooks {
    using Checkpoints for Checkpoints.Trace208;

    IVault public immutable VAULT;
    uint256 public historyStartedAt;
    Checkpoints.Trace208 private supplyHistory;

    error InvalidVault();
    error InactiveHook();
    error HistoryNotStarted();
    error IncompleteHistory();
    error InvalidSnapshotTime();
    error ImmutableConfig();

    constructor(IVault vault_) {
        if (address(vault_).code.length == 0) revert InvalidVault();
        VAULT = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != address(VAULT)) revert CallerNotVault();
        _;
    }

    function name() external pure returns (string memory) {
        return "StakedRailSupplyHook";
    }

    function getConfig() external pure returns (Config memory config) {
        config = Config(true, true, true, true, true, true, true, true, true, true);
    }

    function setConfig(Config memory) external pure {
        revert ImmutableConfig();
    }

    /// @notice Seed existing supply after installation. Later calls cannot repair a history gap.
    function checkpoint() external {
        if (address(VAULT.hooks()) != address(this)) revert InactiveHook();
        if (historyStartedAt == 0) {
            historyStartedAt = block.timestamp;
        } else {
            assertActive();
        }
        _record();
    }

    /// @notice Reject detached hooks and detectable missed changes, including transient supply changes.
    function assertActive() public view {
        if (address(VAULT.hooks()) != address(this)) revert InactiveHook();
        if (historyStartedAt == 0) revert HistoryNotStarted();
        if (supplyHistory.latest() != VAULT.totalSupply()) revert IncompleteHistory();
    }

    function totalSupplyBefore(uint256 timestamp) external view returns (uint256) {
        assertActive();
        if (timestamp == 0 || timestamp > block.timestamp) revert InvalidSnapshotTime();
        if (timestamp <= historyStartedAt) return 0;
        return supplyHistory.upperLookupRecent(SafeCast.toUint48(timestamp - 1));
    }

    function _record() private {
        if (address(VAULT.hooks()) != address(this)) revert InactiveHook();
        if (historyStartedAt == 0) revert HistoryNotStarted();
        supplyHistory.push(SafeCast.toUint48(block.timestamp), SafeCast.toUint208(VAULT.totalSupply()));
    }

    function beforeDeposit(DepositParams memory) external view onlyVault {
        assertActive();
    }

    function afterDeposit(DepositParams memory) external onlyVault {
        _record();
    }

    function beforeMint(MintParams memory) external view onlyVault {
        assertActive();
    }

    function afterMint(MintParams memory) external onlyVault {
        _record();
    }

    function beforeWithdraw(WithdrawParams memory) external view onlyVault {
        assertActive();
    }

    function afterWithdraw(WithdrawParams memory) external onlyVault {
        _record();
    }

    function beforeRedeem(RedeemParams memory) external view onlyVault {
        assertActive();
    }

    function afterRedeem(RedeemParams memory) external onlyVault {
        _record();
    }

    function beforeProcessAccounting(BeforeProcessAccountingParams memory) external view onlyVault {
        assertActive();
    }

    function afterProcessAccounting(AfterProcessAccountingParams memory) external onlyVault {
        _record();
    }
}
