# rail-vault

Foundry scaffold for an auto-compounding RAIL vault built on YieldNest vault primitives.

## Layout

- `lib/yieldnest-vault`: YieldNest vault submodule.
- `lib/yieldnest-vault-withdrawals`: YieldNest withdrawals submodule placeholder.
- `src/RAILxVault.sol`: thin RAILx vault inheriting YieldNest `Vault`.
- `src/RailStakingWithdrawer.sol`: processor-driven bag/withdrawer that models liquid RAIL, active staked RAIL, and queued RAIL.
- `src/tokens/QueuedRailToken.sol`: transferable queued-RAIL representation.
- `src/withdrawals/RailWithdrawalNFT.sol`: withdrawal NFT that can be filled with queued RAIL and later claimed for RAIL.
- `script/DeployRailSystem.s.sol`: proxy deployment for provider, queued token, withdrawer, withdrawal NFT, and RAILx vault.

## Commands

```sh
git submodule update --init --recursive
forge test
```

Deploy with:

```sh
RAIL=0x... RAIL_STAKING=0x... forge script script/DeployRailSystem.s.sol --rpc-url $RPC_URL --broadcast
```

`ADMIN` must be the broadcasting account for initial setup because YieldNest grants only `DEFAULT_ADMIN_ROLE` during initialization. Set `UNPAUSE=true` to unpause the vault and withdrawer in the same script run.

The root `src/` and `script/` directories include compatibility symlinks for YieldNest's root-relative imports (`src/...` and `script/Contracts.sol`) so Foundry's compiler and lint resolver agree without modifying the submodule.

## Note

The public `yieldnest-vault-withdrawals` repo currently only contains a README, so this scaffold includes a local withdrawal NFT and queued RAIL token while keeping the submodule in place.
