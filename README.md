# rail-vault

Foundry project for the stRAIL YieldNest RAIL staking strategy described in
`stRAIL_YieldNest_Spec.md`.

## Layout

- `lib/yieldnest-vault`: YieldNest vault submodule.
- `lib/yieldnest-vault-withdrawals`: YieldNest withdrawal request, Bag, factory, policy, and withdrawer interfaces.
- `src/core/StakedRailStrategy.sol`: YieldNest `BaseStrategy` vault for stRAIL, with RAIL as the base asset and synchronous exits disabled.
- `src/core/QueuedRailStrategy.sol`: YieldNest `BaseStrategy` accepting UnlockedRail deposits and settling qRAIL withdrawals in RAIL.
- `src/core/RailProvider.sol`: RAIL and live qRAIL exchange rates for vault accounting.
- `src/core/RailReceiptToken.sol`: minimal OZ ERC20 used for ActiveRail and UnlockedRail; only the position manager can mint or burn.
- `src/processors/StakedRailProcessor.sol`: permissionless chunked staking and qRAIL exits through stRAIL's processor.
- `src/core/RailStakePositionManager.sol`: records RAILGUN stake IDs, issues/burns principal receipts, queues full positions, and claims matured stakes.
- `lib/yieldnest-vault-withdrawals/src/withdrawers/BaseWithdrawer.sol`: existing YieldNest adapter plugged directly into `WithdrawalRequest` for qRAIL redemptions.
- `src/processors/QueuedRailProcessor.sol`: claims matured RAIL into qRAIL through its processor.
- `src/withdrawals/SingleAssetFIFOResolver.sol`: permissionless FIFO settlement of qRAIL withdrawal requests.
- `script/DeployStakedRail.s.sol`: proxy deployment and role wiring.
- `script/RailStrategyDeployer.sol`: shared single-use deployer used by the script and mainnet integration tests; constructor configuration, parameterless `deploy()`.
- `script/libraries/RailDeploymentLib.sol`: externally linked deployment libraries that keep child creation code out of the deployer runtime.

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

`ADMIN` can differ from the broadcasting account. The script deploys
`RailStrategyDeployer` with constructor configuration, then calls its parameterless
`deploy()`. External deployment libraries must be linked/deployed by Foundry.
The deployer configures the system atomically, assigns proxy ownership and roles
to `ADMIN`, and relinquishes all temporary permissions. Only its creator can
call `deploy()`, and only one successful deployment is allowed.

Before broadcasting, run `forge build --sizes` and check deployment gas against
the target network's limits. Passing fork tests alone does not establish that
the implementations and linked libraries meet on-chain deployment limits.

## Notes

YieldNest dependencies are resolved with context remappings, including
`lib/yieldnest-vault:src=lib/yieldnest-vault/src` and
`lib/yieldnest-vault-withdrawals:src=lib/yieldnest-vault-withdrawals/src`, so no root-level compatibility symlinks are required.
