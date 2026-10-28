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
- `src/processors/RailRewardsProcessor.sol`: permissionless forwarding of already-claimed manager balances to a fixed Splits Swapper; RAIL bypasses swapping and goes to its configured beneficiary. No harvesting, keeper role or arbitrary transfers.
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
RAIL=0x... RAIL_STAKING=0x... SPLITS_SWAPPER=0x... forge script script/DeployStakedRail.s.sol --rpc-url $RPC_URL --broadcast
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

### Reward forwarding

Deploy and configure a Splits **Swapper instance** separately, with RAIL as
`tokenToBeneficiary` and the intended reward receiver as `beneficiary`. Set
`SPLITS_SWAPPER` to that instance, not the factory or callback integration.
The rewards processor validates the output token at construction and stores both
the swapper and beneficiary as immutable destinations. Keep this Splits output
configuration unchanged; changing it requires replacing the forwarder and updating
the manager's `TOKEN_WITHDRAWER_ROLE`. Splits ownership and oracle configuration
remain trusted governance responsibilities.

Anyone can claim on the Railgun rewards distributor for the position manager,
then anyone can call `collectTokens(tokens)` on the processor. Non-RAIL tokens go
directly from the manager to Splits; RAIL goes directly to the fixed beneficiary.
There is no token registry, claim cursor, keeper role, custody step or arbitrary
recipient parameter. Do not send funds to the processor itself. Duplicate tokens
and zero balances are harmless; a failing token reverts the batch, so retry other
tokens separately. Unsupported reward tokens still require Splits oracle/pricing
configuration before they can be exchanged.

Funding Splits does **not** execute a swap. A separate permissionless trader calls
its integration to settle into RAIL. Neither restaking nor shareholder reward
allocation/accounting is implemented here; choose the beneficiary deliberately
rather than assuming a vault donation safely compounds rewards.

Unit/deployer tests use a mock Splits funding destination. The mainnet fork tests
also create test-owned instances through the deployed Splits Swapper and UniV3
oracle factories, and execute the deployed UniV3 integration against the real
RAIL/WETH 1% pool. They cover separate Railgun claiming and forwarding, WETH-to-RAIL
settlement, oracle-underpayment rollback, and RAIL bypass. No mainnet transactions
are sent. The 30-minute TWAP and 95% offer factor are test settings, not production
recommendations; DAI/other-token pricing and routing are not covered by this test.

```sh
FOUNDRY_PROFILE=mainnet forge test --fork-url "$ETH_MAINNET_RPC_URL" --fork-block-number 26195542 --match-contract RailRewardsSplitsIntegrationTest -vv
FOUNDRY_PROFILE=mainnet forge test --fork-url "$ETH_MAINNET_RPC_URL" --fork-block-number 26195542 --match-test testCollectRealRewardsAfterPermissionlessClaim -vv
```

### Upgradeability

New deployments use OpenZeppelin TransparentUpgradeableProxy (TUP) instances for
stRAIL, qRAIL, the position manager, aRAIL/uRAIL receipts, both providers, withdrawal
requests, the withdrawer, FIFO resolver and bag factory.
Each TUP has its own ProxyAdmin, initially owned by `ADMIN`. Initializers
run atomically during proxy creation and implementation initializers are disabled.

Withdrawal bags retain the existing `BeaconProxyFactory` architecture: the factory
itself is a TUP, while bags are beacon proxies sharing a factory-owned beacon.
`ADMIN` holds the factory's `IMPLEMENTATION_MANAGER_ROLE`; calling
`upgradeImplementation` upgrades all existing bags and the implementation used by
future bags. Bags do not have individual ProxyAdmins.

The three processors and the dependency's original `MinAmountRequestPolicy` remain
constructor-based, non-upgradeable contracts. External
RAIL/RAILGUN contracts, deployment libraries and the single-use deployment helper
are not converted. This is a fresh-deployment layout, not an in-place migration of
old direct deployments or beacon factories. Future upgrades must preserve storage
layout and use authorized, versioned reinitializers only when necessary.

YieldNest dependencies are resolved with context remappings, including
`lib/yieldnest-vault:src=lib/yieldnest-vault/src` and
`lib/yieldnest-vault-withdrawals:src=lib/yieldnest-vault-withdrawals/src`, so no root-level compatibility symlinks are required.
