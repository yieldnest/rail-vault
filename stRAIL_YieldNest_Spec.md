# stRAIL --- YieldNest RAIL Staking Vault Specification

## Objective

Build a YieldNest `BaseStrategy` vault named **Staked RAIL (`stRAIL`)**,
with **RAIL** as the base asset. RAIL is staked in discrete positions
against the RAILGUN staking contract. Because exits from the underlying
staking system are asynchronous, normal user-facing ERC-4626 `withdraw`
and `redeem` operations are disabled.

Dependencies:

-   YieldNest Vault: https://github.com/yieldnest/yieldnest-vault
-   YieldNest Withdrawals:
    https://github.com/yieldnest/yieldnest-vault-withdrawals
-   RAILGUN docs: https://docs.railgun.org/wiki/learn/helpful-links
-   RAILGUN staking: `0xEE6A649Aa3766bD117e12C161726b693A1B2Ee20`

## Architecture

``` text
RAIL -> stRAIL
          |
          +-> idle RAIL
          |
          +-> ActiveRail / RAILGUN stake chunks
                    |
                    | queue whole positions
                    v
             RailStakePositionManager
                    |
                    | burn ActiveRail, mint UnlockedRail 1:1
                    v
                UnlockedRail
                    |
                    | deposit at live qRAIL rate
                    v
                  qRAIL
                    |
                    | reserve against requests
                    v
             WithdrawalRequest
                    |
              Request NFTs / Bags
                    |
                    | resolver / keeper
                    v
              matured stake claims
                    |
                    v
                  RAIL
                    |
                    v
              user claims RAIL
```

The system separates five concepts:

1.  `stRAIL`: fungible ownership of the overall strategy.
2.  RAILGUN `stakeID`s: external staking positions.
3.  `qRAIL`: fungible representation of RAIL already committed to
    unstaking.
4.  Withdrawal request NFTs: individual user exit claims.
5.  Resolver/keeper logic: maps aggregate unstaking liquidity onto
    requests.

Users never interact with individual stake IDs.

## Existing YieldNest Components

### `yieldnest-vault`

Reuse `BaseStrategy`, `BaseVault` accounting, roles, hooks and
conversion logic.

``` solidity
contract StakedRailStrategy is BaseStrategy
```

No modification of generic `BaseStrategy` should be required.

### `yieldnest-vault-withdrawals`

Reuse:

-   `WithdrawalRequest`
-   `Bag`
-   `BeaconProxyFactory`
-   request NFT
-   request policies
-   resolver model
-   viewer infrastructure

Canonical lifecycle:

``` text
requestWithdrawal()
 -> stRAIL locked
 -> Bag created
 -> request NFT minted
 -> resolver settles
 -> RAIL transferred to Bag
 -> NFT owner claims RAIL
```

Do not build a second withdrawal queue.

## New Components

``` text
StakedRailStrategy
QueuedRail (qRAIL)
RailStakePositionManager
SingleAssetFIFOResolver
```

Recommended layout:

``` text
src/
├── core/
│   ├── StakedRailStrategy.sol
│   ├── QueuedRailStrategy.sol
│   ├── RailProvider.sol
│   ├── RailReceiptToken.sol
│   └── RailStakePositionManager.sol
├── railgun/
│   ├── IRailgunStaking.sol
│   └── IRailgunGovernorRewards.sol
├── withdrawals/
│   └── SingleAssetFIFOResolver.sol
└── interface/
```

## StakedRailStrategy

The initializer forwards all base initialization parameters to `_initialize`
and stores the position manager and qRAIL references. `StakedRailSetupLib`
configures the provider, assets, and qRAIL withdrawal permission in the same
deployment transaction, then revokes its temporary configuration roles.

Base asset:

``` solidity
asset() == RAIL
```

Responsibilities:

-   accept RAIL deposits;
-   issue stRAIL;
-   account for idle RAIL;
-   account for active RAILGUN principal;
-   account for queued/unstaking principal;
-   expose total strategy value in RAIL;
-   delegate stake-ID mechanics to `RailStakePositionManager`;
-   disable synchronous user exits.

The strategy should not contain request-NFT, FIFO, or per-user RAILGUN
position logic.

## Accounting

Every unit of economically owned RAIL must be counted exactly once.

``` text
stRAIL assets = idleRAIL + ActiveRail balance
             + value of qRAIL held
qRAIL assets = idleRAIL + UnlockedRail balance
```

Both vaults use inherited balance-based accounting, without total-assets
overrides. ActiveRail and UnlockedRail are transferable OZ ERC20 receipts,
valued at one RAIL per unit. Only the manager may mint or burn them.
Their total supplies equal active and queued principal respectively; no
separate principal counters are stored.

qRAIL is a vault share, not a fixed-rate receipt. RAIL donations increase
its exchange rate. Depositing UnlockedRail through `depositAsset` issues
shares at the current rate rather than minting principal-for-shares.
Only receipts held by a vault contribute to that vault's assets.
UnlockedRail is accounted for only in qRAIL; stRAIL holds it transiently
during the atomic queue-and-deposit operation, not as a registered asset.

## Disable Direct Withdrawals

Configure RAIL as non-withdrawable through `BaseStrategy`:

``` solidity
_setAssetWithdrawable(RAIL, false);
```

Normal users should therefore observe:

``` text
maxWithdraw(user) = 0
maxRedeem(user)   = 0
```

The withdrawal-request system is the canonical exit route.

## Chunked Staking

Configuration should include:

``` solidity
uint256 public stakeChunkSize;
```

Anyone can trigger staking in full chunks, bounded by `maxOperations`.
Only `CONFIG_MANAGER_ROLE` can change the nonzero chunk size, initially
1000 RAIL. Any remainder smaller than a chunk stays in the vault.
Every resulting RAILGUN `stakeID` is recorded.

Withdrawal requests do not map 1:1 to stake chunks. Multiple requests
may be serviced by one queued chunk and one request may require multiple
chunks.

## RailStakePositionManager

Expose the two receipts:

``` solidity
RailReceiptToken public immutable activeRail;
RailReceiptToken public immutable unlockedRail;
```

Responsibilities:

-   interact with RAILGUN staking;
-   create/register stakes;
-   initiate unstaking;
-   derive position state from RAILGUN's locktime and claimedTime;
-   mint ActiveRail to the creator after staking;
-   burn the queuer's ActiveRail and mint UnlockedRail after successful queueing;
-   claim matured positions;
-   burn the claimer's UnlockedRail when claiming principal;
-   return RAIL to the exit system.

Derived lifecycle (not stored locally):

``` text
ACTIVE -> UNSTAKING -> CLAIMABLE -> CLAIMED
```

Use actual deployed RAILGUN state wherever possible rather than
duplicating timing assumptions.
Separate active-position and claimable-position checks read the principal,
locktime, and claimedTime directly from RAILGUN. No per-position metadata
is stored locally; the active stake-ID list is maintained and receipt
supplies represent aggregate principal. Keepers discover queued IDs from `PositionQueued`
events and supply them when claiming. Claimed stakes are rejected first; claims require
a nonzero locktime strictly less than the current timestamp. Nonexistent
stake IDs revert in RAILGUN's stake lookup.

## qRAIL

`qRAIL` is a YieldNest `BaseStrategy` share backed by UnlockedRail and
liquid RAIL. Its inherited conversions determine the live exchange rate.
Its initializer forwards all base-vault initialization parameters: admin,
name, symbol, decimals, pause state, native-asset accounting, live accounting,
and default asset index. The deployment chooses the qRAIL defaults.
The shared deployment setup library creates and assigns the provider, registers assets,
enables allocator checks and configures withdrawability in the same deployment
transaction, then revokes its temporary setup roles.

``` text
Name: Queued RAIL
Symbol: qRAIL
Decimals: same as RAIL
Initial exchange rate: 1 qRAIL = 1 RAIL
Donations can increase this rate.
```

Asset configuration:

``` text
RAIL: base asset, deposits disabled, withdrawals enabled
UnlockedRail: deposits enabled, withdrawals disabled, provider rate 1:1
```

New qRAIL shares are issued by the inherited deposit path in exchange for
UnlockedRail, not by a privileged mint method. stRAIL rejects a queue/deposit
that would mint zero shares. This does not eliminate ordinary vault rounding
or donation-driven exchange-rate changes.

qRAIL enables allocator checks. Only stRAIL and the configured
`BaseWithdrawer` receive `ALLOCATOR_ROLE`: stRAIL deposits receipts and the
withdrawer settles RAIL into Bags. Holding qRAIL does not permit direct
redemption without this role. Transfers, approvals and processor calls are
unaffected.

The manager burns UnlockedRail on claim and transfers the matching RAIL
into qRAIL. This changes the composition of backing, not its total value.

## Queueing a Stake

``` solidity
function queuePosition()
    external
    onlyRole(QUEUER_ROLE)
    returns (uint256 principal);
```

The manager's `QUEUER_ROLE` belongs to stRAIL. `StakedRailProcessor` invokes
`StakedRailStrategy.queuePosition()` through stRAIL's processor;
this instruction is restricted to an allowlisted processor self-call.

Active stake IDs are held in OpenZeppelin's `DoubleEndedQueue`. New stakes
are appended at the back; queueing always consumes the oldest from the
front in O(1). Callers cannot select an arbitrary stake. The read-only
`activeStakeIdsList()` enumerates the queue in O(n).

Required ordering within that instruction:

1.  Pop the oldest active stake ID (revert if empty).
2.  Verify the stake is ACTIVE.
3.  Determine its principal.
4.  Burn that amount of ActiveRail from the caller.
5.  Successfully initiate external unstaking.
6.  Mint the same amount of UnlockedRail to the caller.
7.  stRAIL approves and deposits UnlockedRail into qRAIL, receiving shares
    at the current exchange rate.

The entire instruction is atomic. Deposit failure reverts the queue pop,
unlock and receipt transitions. There is no privileged qRAIL mint function
or circular deployment dependency. Each proxy is initialized in its constructor.
When claiming, the manager burns UnlockedRail from the caller and transfers
the claimed RAIL to the receiver. The qRAIL processor rules restrict that
receiver to qRAIL, replacing receipt backing with liquid RAIL atomically.

## User Withdrawal Requests

Users request exits in stRAIL shares:

``` solidity
WithdrawalRequest.requestWithdrawal(
    shares,
    receiver,
    data
);
```

The existing module locks stRAIL, creates the Bag and mints the request
NFT.

Withdrawal demand is aggregated. For example:

``` text
Requests: 10k + 7k + 14k + 4k = 35k RAIL
Chunks:   20k + 20k + 20k
```

The keeper can queue two chunks, producing 40k qRAIL, which services the
FIFO queue.

## Withdrawer

Use YieldNest's existing `BaseWithdrawer` directly, initialized with qRAIL
and the `WithdrawalRequest` contract. No RAIL-specific adapter is needed.

The resolver obtains RAIL's address from `qRail.asset()`. For settlement,
`BaseWithdrawer` forwards the authorized withdrawal to qRAIL, consuming
locked qRAIL shares and transferring RAIL into the request Bag. The generic
`WithdrawalRequest` balance-delta accounting remains unchanged.

## Two-Stage Exit

Internal economics:

``` text
stRAIL -> qRAIL -> RAIL
```

User-facing UX:

``` text
stRAIL -> Request NFT -> RAIL
```

Recommended flow:

``` text
stRAIL request
 -> stRAIL locked
 -> qRAIL allocated/reserved
 -> external position matures
 -> RAIL claimed
 -> request settled into Bag
 -> NFT owner claims RAIL
```

qRAIL should normally remain internal.

## Reservation Accounting

Track qRAIL assigned to individual requests:

``` solidity
mapping(uint256 => uint256) public qRailReserved;
uint256 public totalReservedQRAIL;
```

Invariant:

``` text
sum(request reservations)
<= qRAIL controlled by exit system
```

State transition:

``` text
unreserved qRAIL
 -> reserved qRAIL
 -> reserved RAIL
 -> request Bag
```

This prevents the same queued principal from backing multiple requests.

## Fixing User Entitlement

Until allocation, locked stRAIL retains normal stRAIL economic exposure.

At allocation:

``` text
S stRAIL * current conversion rate = R RAIL
```

Then:

``` text
S stRAIL consumed
R qRAIL reserved
```

The request now has a fixed RAIL entitlement and no longer participates
in subsequent stRAIL yield or loss.

## SingleAssetFIFOResolver

Implement:

``` solidity
contract SingleAssetFIFOResolver
```

Grant:

``` text
WithdrawalRequest.RESOLVER_ROLE -> SingleAssetFIFOResolver
```

Responsibilities:

-   enforce request ordering;
-   resolve locked qRAIL shares into RAIL at the live redemption rate;
-   retain partially settled requests at the head until fully resolved.

Settlement uses **strict FIFO with partial fills**.

``` text
request N+1 must not consume liquidity
required to fully satisfy unresolved request N
```

Bound keeper work with separate calls on separate contracts:

``` solidity
// QueuedRailProcessor
function claimMaturedPositions(uint256[] calldata stakeIds) external;
// SingleAssetFIFOResolver
function resolveRequests(uint256 maxRequests) external;
```

## Rebalancing

Staking keeper:

``` solidity
function rebalanceStaking(uint256 maxOperations)
```

It creates full stake chunks and leaves only a sub-chunk remainder when
the operation limit permits staking all available chunks.

Each chunk uses one atomic stRAIL processor batch: approve the position
manager for the chunk amount, then call `createPosition(amount)`. The
manager pulls RAIL from its caller with `safeTransferFrom` before staking;
it does not use any pre-existing manager balance to fund the position.

`StakedRailProcessor` invokes stRAIL's atomic queue-and-deposit instruction for
complete stake positions. It then redeems the user's stRAIL shares
for qRAIL, which the user can submit to the withdrawal queue.

Excess qRAIL from whole-position exits remains in stRAIL for later exits.
No separate exit rebalancing is needed: withdrawal requests already hold
backed qRAIL. `QueuedRailProcessor` claims matured positions into qRAIL;
the resolver settles requests in FIFO order as RAIL becomes available.

## Rewards

Recommended V1:

-   RAIL rewards are realized into stRAIL NAV.
-   Non-RAIL rewards are harvested and converted to RAIL through
    approved YieldNest processing.
-   Avoid valuing arbitrary unclaimed rewards unless an explicit
    oracle/accounting design is added.

## Request Status View

A RAIL-specific viewer may expose:

``` solidity
enum RailRequestStatus {
    PENDING,
    QUEUED,
    CLAIMABLE,
    CLAIMED
}
```

-   `PENDING`: stRAIL locked; no qRAIL allocated.
-   `QUEUED`: stRAIL consumed; fixed RAIL entitlement; qRAIL reserved.
-   `CLAIMABLE`: final RAIL is in the request Bag.
-   `CLAIMED`: Bag assets have been claimed.

## Generic Contracts Stay Generic

Do not put RAILGUN-specific logic into:

-   `WithdrawalRequest.sol`
-   `Bag.sol`
-   request NFT ownership logic

RAIL-specific behavior belongs in the strategy, position manager,
withdrawer, resolver and viewer.

## Roles

Use existing YieldNest strategy roles plus:

``` text
RailStakePositionManager:
  DEFAULT_ADMIN_ROLE
  CREATOR_ROLE -> StakedRailStrategy (createPosition)
  QUEUER_ROLE -> StakedRailStrategy (queuePosition)
  CLAIMER_ROLE -> QueuedRailStrategy (claimPosition / claimMaturedPositions)
  TOKEN_WITHDRAWER_ROLE -> RailRewardsProcessor (generic ERC-20 transferToken)
  PAUSER_ROLE -> pause / unpause (initially granted to config.admin)

stRAIL:
  PROCESSOR_ROLE -> StakedRailProcessor (staking and exits)

qRAIL:
  DEFAULT_ADMIN_ROLE
  PROCESSOR_ROLE -> QueuedRailProcessor
  ALLOCATOR_ROLE -> StakedRailStrategy, BaseWithdrawer
  deposits -> UnlockedRail only, via inherited depositAsset

ActiveRail / UnlockedRail:
  mint / burn -> RailStakePositionManager only

WithdrawalRequest:
  existing roles
  RESOLVER_ROLE -> SingleAssetFIFOResolver
```

The resolver module, rather than a normal keeper EOA, should hold
settlement authority.

`QueuedRailProcessor` claims matured stakes through qRAIL's processor.
It gates claims with `KEEPER_ROLE`; the resolver's `resolveRequests` is
permissionless and always settles FIFO into the request Bags. The
processor has no request-resolution authority, and the
resolver has no qRAIL processor authority. Only qRAIL
receives the manager's `CLAIMER_ROLE` in deployment. Processor rules allow
single and batch claim calls to the manager and restrict the receiver to
qRAIL itself. Governance can manage these rules and role grants.

## Governance Control and Upgrades

RAILGUN governance controls these deployments through its mainnet
Delegator (`0xB6d513f6222Ee92Fff975E901bd792E2513fB53B`):

- Grant Delegator the contracts' admin and configuration roles.
- Transfer ownership of each vault and withdrawal-system ProxyAdmin to
  Delegator, and grant it the Bag factory's implementation-manager role.
- Remove the deployer's privileges after verifying the handoff.

Approved proposals execute through `Voting -> Delegator -> target`.
Delegator can then grant or revoke roles, change configuration, upgrade
proxy implementations, and update the Bag implementation. Non-proxied
modules require replacement and rewiring or migration for code changes.

For immediate emergency pausing, governance can authorize a guardian
through Delegator for a specific target's `pause()` selector, provided
Delegator holds the target's pause authority. Unpausing and upgrades
remain under governance.

The shared `RailStrategyDeployer` performs the admin handoff atomically to
the configured `ADMIN`, which may be Delegator rather than the broadcaster.
Guardian authorization remains a separate governance action. The deployer
accepts configuration in its constructor; its parameterless `deploy()` uses
externally linked deployment libraries, wires all roles and processor rules,
and relinquishes its temporary permissions. The mainnet integration fixture
uses this same deployment path.

## Emergency Behavior

Use independent pause domains:

1.  Deposit pause: stop new stRAIL deposits.
2.  Position manager pause: stop new stakes, unstaking, and matured
    principal claims, including claims through nonempty batches.
3.  Request pause: stop new requests while permitting existing request
    resolution.

Matured principal claims resume after the position manager is unpaused.
Settlement of existing requests backed by RAIL already held in qRAIL
remains independent of the position manager's pause.

## Cancellation

Recommended:

``` text
PENDING:
  cancellable back into stRAIL using the existing
  cancellation-in-kind mechanism.

QUEUED:
  normally irreversible because stRAIL exposure has
  already become a fixed RAIL entitlement.
```

Do not recreate stRAIL after qRAIL reservation unless a deliberate
re-entry mechanism is designed.

## Core Invariants

Invariant tests must cover:

1.  ActiveRail supply equals active principal; UnlockedRail supply equals
    unclaimed queued principal. qRAIL accounts only for receipts and RAIL it holds.
2.  Reserved qRAIL never exceeds qRAIL controlled by the exit system.
3.  Active plus queued principal reconciles to external non-claimed
    positions.
4.  A position cannot be ACTIVE and UNSTAKING simultaneously.
5.  A stake ID cannot mint UnlockedRail twice or be claimed twice.
6.  A stake ID cannot be claimed twice.
7.  Every allocated request's RAIL entitlement equals its reservation.
8.  stRAIL shares are consumed exactly once.
9.  Every unit of RAIL principal exists in exactly one accounting state.
10. Later FIFO requests cannot consume earlier reserved liquidity.

## Tests

Mainnet-fork coverage against the deployed RAILGUN staking contract must
verify:

-   staking and stake-ID generation;
-   queue/unstake behavior;
-   actual unlock/claimability semantics;
-   claiming RAIL;
-   multiple concurrent stake IDs;
-   reward behavior;
-   external failure/revert behavior.

Unit/invariant coverage should include deposits, multiple chunks, idle
buffers, queueing, qRAIL mint/burn, withdrawal requests, reservation,
FIFO behavior, NFT transfer, claims, cancellation, pauses, excess
chunks, and randomized sequences of all state transitions.

## Example

Assume:

``` text
totalAssets = 1,000,000 RAIL
stRAIL supply = 950,000
1 stRAIL = 1.052631 RAIL
```

Alice requests 9,500 stRAIL, worth 10,000 RAIL at allocation.

The next external chunk is 25,000 RAIL. The keeper queues that complete
position:

``` text
ActiveRail burned  = 25,000
UnlockedRail minted and deposited into qRAIL = 25,000
qRAIL minted = deposit preview (25,000 only at a 1:1 exchange rate)
```

Alice receives a 10,000 qRAIL reservation. The remaining 15,000 qRAIL
stays unreserved for later requests.

When the position matures, 25,000 UnlockedRail held by qRAIL is burned and
25,000 RAIL is claimed into qRAIL. Alice's 10,000 RAIL becomes reserved
final liquidity. The resolver settles her request into its Bag, and the
request NFT owner claims 10,000 RAIL.

The remaining 15,000 RAIL can satisfy later requests or be restaked.

## Repository Boundary

`yieldnest-vault` should remain generic and provide the `BaseStrategy`
framework.

`yieldnest-vault-withdrawals` should remain generic and provide request
custody, NFTs, Bags, resolver-gated settlement and claim mechanics.

The RAIL-specific repository/module should contain:

``` text
StakedRailStrategy
QueuedRail
IRailgunStaking
RailStakePositionManager
SingleAssetFIFOResolver
deployment scripts
mainnet-fork tests
```

## Final Design Principle

``` text
YieldNest accounting:
RAIL -> stRAIL -> active/queued strategy value

RAILGUN:
stakeID -> ACTIVE -> UNSTAKING -> CLAIMABLE -> CLAIMED

User withdrawals:
stRAIL -> Request NFT -> Bag -> RAIL
```

`qRAIL` bridges YieldNest strategy accounting and RAILGUN's asynchronous
positional exit lifecycle. YieldNest's `BaseWithdrawer` and `SingleAssetFIFOResolver`
bridge that internal liquidity state into the existing YieldNest
withdrawal-request system.

This keeps the implementation small, auditable and aligned with the
existing YieldNest architecture.
