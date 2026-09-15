# rail-vault

Foundry project for the stRAIL YieldNest RAIL staking strategy described in
`stRAIL_YieldNest_Spec.md`.

## Layout

- `lib/yieldnest-vault`: YieldNest vault submodule.
- `lib/yieldnest-vault-withdrawals`: YieldNest withdrawals submodule. At the current pinned revision it only contains a README, so this repo includes minimal local withdrawal request / Bag / resolver contracts that follow the requested model.
- `src/StakedRailStrategy.sol`: YieldNest `BaseStrategy` vault for stRAIL, with RAIL as the base asset and synchronous exits disabled.
- `src/railgun/RailStakePositionManager.sol`: records RAILGUN stake IDs, tracks active and queued principal, mints qRAIL after successful unstaking queueing, and claims matured stakes.
- `src/QueuedRail.sol`: ERC20 qRAIL, minted only for queued RAIL principal.
- `src/withdrawals/`: local request NFT, Bag, withdrawer, and resolver contracts for FIFO full-fill exits.
- `src/views/StakedRailViewer.sol`: lightweight status/accounting viewer.
- `script/DeployStakedRail.s.sol`: proxy deployment and role wiring.

## Commands

```sh
git submodule update --init --recursive
forge build
forge test
```

Deploy with:

```sh
RAIL=0x... RAIL_STAKING=0x... forge script script/DeployStakedRail.s.sol --rpc-url $RPC_URL --broadcast
```

Optional deployment environment variables:

- `STAKE_CHUNK_SIZE`, default `1000 ether`
- `MINIMUM_STAKE_AMOUNT`, default `1000 ether`
- `TARGET_IDLE_RAIL`, default `1000 ether`
- `MAX_ACTIVE_POSITIONS`, default `1000`
- `UNPAUSE`, default `false`

`ADMIN` must be the broadcasting account for initial setup because YieldNest initializes only `DEFAULT_ADMIN_ROLE`.

## Notes

The root `src/` and `script/` directories include compatibility symlinks for YieldNest's root-relative imports (`src/...` and `script/Contracts.sol`) so Foundry's compiler and lint resolver agree without modifying the submodule.
