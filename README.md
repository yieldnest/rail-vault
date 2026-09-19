# rail-vault

Foundry project for the stRAIL YieldNest RAIL staking strategy described in
`stRAIL_YieldNest_Spec.md`.

## Layout

- `lib/yieldnest-vault`: YieldNest vault submodule.
- `lib/yieldnest-vault-withdrawals`: YieldNest withdrawal request, Bag, factory, policy, and withdrawer interfaces.
- `src/StakedRailStrategy.sol`: YieldNest `BaseStrategy` vault for stRAIL, with RAIL as the base asset and synchronous exits disabled.
- `src/QueuedRailStrategy.sol`: non-depositable YieldNest `BaseStrategy` qRAIL token used by the withdrawal system.
- `src/processors/StakedRailStakingProcessor.sol`: keeper-facing staking processor that calls stRAIL `processor`.
- `src/processors/StakedRailExitProcessor.sol`: user-facing exit processor that burns stRAIL and mints qRAIL through vault processors.
- `src/railgun/RailStakePositionManager.sol`: records RAILGUN stake IDs, tracks active/queued principal, queues full positions, and claims matured stakes.
- `lib/yieldnest-vault-withdrawals/src/withdrawers/BaseWithdrawer.sol`: existing YieldNest adapter plugged directly into `WithdrawalRequest` for qRAIL redemptions.
- `src/withdrawals/RailWithdrawalResolver.sol`: FIFO resolver/keeper helper for claiming matured RAIL and resolving qRAIL withdrawal requests.
- `src/views/StakedRailViewer.sol`: lightweight status/accounting viewer.
- `script/DeployStakedRail.s.sol`: proxy deployment and role wiring.

## Commands

```sh
git submodule update --init --recursive
forge build
forge test
FOUNDRY_PROFILE=mainnet forge test
```

The default profile runs unit tests. The `mainnet` profile runs integration
tests against `ETH_MAINNET_RPC_URL` from `.env`. To pin the fork, pass
`--fork-block-number <block>` to the mainnet test command.

Deploy with:

```sh
RAIL=0x... RAIL_STAKING=0x... forge script script/DeployStakedRail.s.sol --rpc-url $RPC_URL --broadcast
```

Optional deployment environment variables:

- `STAKE_CHUNK_SIZE`, default `1000 ether`
- `UNPAUSE`, default `false`

`ADMIN` must be the broadcasting account for initial setup because YieldNest initializes only `DEFAULT_ADMIN_ROLE`.

## Notes

YieldNest dependencies are resolved with context remappings, including
`lib/yieldnest-vault:src=lib/yieldnest-vault/src` and
`lib/yieldnest-vault-withdrawals:src=lib/yieldnest-vault-withdrawals/src`, so no root-level compatibility symlinks are required.
