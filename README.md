# rail-vault

Foundry project for the stRAIL YieldNest RAIL staking strategy described in
`stRAIL_YieldNest_Spec.md`.

## stRAIL governance locks

`StakedRailVoting` holds non-transferable lock positions denominated in stRAIL
shares. Users approve the contract and call `lock(shares)`. Shares stay locked
indefinitely until the owner calls `requestUnlock(lockId)`. Each deposit creates
a separate lock. There are no transferable receipts, top-ups that inherit an old
timestamp, early withdrawals, administrator withdrawals, or arbitrary execution
methods.

For a RAILGUN proposal, a lock must exist **strictly before the start of its
staking snapshot interval** and have no pending unlock request. Each successful
vote records the latest final NO-vote deadline the lock must remain held through.
Locking after a proposal's cutoff does not grant voting rights for that proposal.
The contract obtains the proposal and manager voting power directly from RAILGUN.
`StakedRailSupplyHook` records total supply through YieldNest deposit, mint,
withdraw, redeem, and accounting callbacks. Later deposits and exits cannot
change the historical allocation denominator. The strategy itself contains no
governance checkpoint logic.

The cumulative voting entitlement of a lock is the smaller of:

```text
floor(locked shares × manager's snapshot voting power / stRAIL supply before cutoff)
current stRAIL.convertToAssets(locked shares)
```

Amounts are RAIL base units. This uses active historical backing per share rather
than assigning votes to idle RAIL or qRAIL. All outstanding shares are included
in the denominator; nonparticipants' votes are not redistributed. Donations
cannot increase a lock above its historical allocation. A lower current value
can reduce unused entitlement, but votes already sent upstream cannot be undone.

The owner calls `vote(lockId, proposalId, railAmount, affirmative, snapshotHint)`.
Votes forward immediately as the manager's registered voting key. A lock can
split its allocation between YES and NO and use its allocation independently on
multiple proposals. There is no choice-changing or revocation mechanism. The
contract enforces RAILGUN's opening, YES deadline, and NO-only veto deadline.
`votingPower` returns the cumulative cap; subtract `votesUsed` for available
power (clamped to zero if valuation has fallen).

`requestUnlock(lockId)` immediately stops further voting for that lock, without
revoking votes already cast. It sets the withdrawal time to:

```text
max(unlock request time + unlockCooldown, latest voted proposal's final NO-vote deadline)
```

The cooldown is immutable and configured at deployment. Requests cannot be
cancelled or restarted, and time spent locked before requesting does not count
toward the cooldown. Even a vote at the end of a voting window is followed by a
full cooldown if the user requests an unlock immediately afterward. Withdrawal
does not wait for proposal execution.

At that time, `withdraw(lockId)` returns the same number of stRAIL shares to their
owner. Unlock requests and withdrawals work independently of the supply hook or
upstream voting permissions. To vote again after requesting an unlock, withdraw
and create a fresh lock, eligible only for subsequent snapshot cutoffs. Shares
retain vault exposure while locked. The lock prevents selling or redeeming those
shares through this contract, but does not prevent external hedging or sale of
account control.

OpenZeppelin's [VestingWallet](https://docs.openzeppelin.com/contracts/5.x/api/finance)
implements scheduled beneficiary releases, while
[Votes and TimelockController](https://docs.openzeppelin.com/contracts/5.x/api/governance)
provide voting checkpoints and delayed transaction execution. None directly
provides this per-lock unlock-request cooldown with RAILGUN proposal deadlines.
The escrow uses a small custom state machine with OZ `SafeERC20`,
`ReentrancyGuard`, and `Math`; the supply hook uses OZ `Checkpoints`.

### Deployment and trust boundaries

The position manager must expose `setVotingKey`; no governance changes to the
strategy implementation are required. Install `StakedRailSupplyHook` directly
with `setHooks`, then call its `checkpoint()` to start history before deploying
the escrow. Earlier history cannot be reconstructed. Locks become eligible only
for later interval cutoffs. The hook has fixed callback settings and cannot mint
shares. This deployment does not compose it with fee hooks or MetaHooks.

`script/DeployStakedRailVoting.s.sol` reads `ST_RAIL`, `RAILGUN_VOTING`, and
`UNLOCK_COOLDOWN` (seconds). It deploys, installs, and initializes the hook,
then deploys the immutable escrow and calls the manager's `setVotingKey`. Execute
as a holder of both the strategy's `HOOKS_MANAGER_ROLE` and the manager's
`DEFAULT_ADMIN_ROLE`, or perform installation and registration separately through
governance. The script rejects an existing hook instead of replacing it. No
deployment is performed automatically.

Removing the hook blocks new locks and voting; unlock requests and matured
withdrawals remain available.
The vault does not notify hooks when they are removed: removal followed by
reinstallation can leave undetectable gaps if supply returns to its recorded
value. Governance must never reuse this history after detaching the hook. Deploy
a new hook and escrow, initialize fresh history, and register the new voting key
instead. Current-supply checks detect mismatches, not every possible history gap.

There is no trusted price or tally input. Existing proxy administrators and vault
configuration roles remain trusted; the manager administrator can replace or
clear the voting key. The script requires live accounting at escrow deployment;
governance must retain that configuration. The escrow itself is not upgradeable
and has no administrator. Sponsorship and proposal creation remain external to
this escrow.

## Contract layout

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
