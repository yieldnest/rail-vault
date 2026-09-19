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
          +-> RAILGUN stake chunks / stakeIDs
                    |
                    | queue whole positions
                    v
             RailStakePositionManager
                    |
                    | mint 1:1 queued principal
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
RailWithdrawalResolver
StakedRailViewer
```

Recommended layout:

``` text
src/
├── StakedRailStrategy.sol
├── QueuedRail.sol
├── railgun/
│   ├── IRailgunStaking.sol
│   └── RailStakePositionManager.sol
├── withdrawals/
│   └── RailWithdrawalResolver.sol
├── interface/
└── views/
    └── StakedRailViewer.sol
```

## StakedRailStrategy

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
totalAssets =
    idleRAIL
  + activePrincipal
  + queuedPrincipal
```

Prefer:

``` solidity
totalAssets =
    RAIL.balanceOf(address(this))
    + positionManager.activePrincipal()
    + positionManager.queuedPrincipal();
```

When a stake transitions from ACTIVE to UNSTAKING:

``` text
activePrincipal -= X
queuedPrincipal += X
```

Never count both the active stake and its qRAIL representation
simultaneously.

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

Maintain:

``` solidity
uint256 public activePrincipal;
uint256 public queuedPrincipal;
```

Responsibilities:

-   interact with RAILGUN staking;
-   create/register stakes;
-   initiate unstaking;
-   derive position state from RAILGUN's locktime and claimedTime;
-   mint qRAIL after successful queueing;
-   claim matured positions;
-   burn/reconcile qRAIL;
-   return RAIL to the exit system.

Derived lifecycle (not stored locally):

``` text
ACTIVE -> UNSTAKING -> CLAIMABLE -> CLAIMED
```

Use actual deployed RAILGUN state wherever possible rather than
duplicating timing assumptions.
Separate active-position and claimable-position checks read the principal,
locktime, and claimedTime directly from RAILGUN. No per-position metadata
is stored locally; only the active stake-ID list and aggregate principal
totals are maintained. Keepers discover queued IDs from `PositionQueued`
events and supply them when claiming. Claimed stakes are rejected first; claims require
a nonzero locktime strictly less than the current timestamp. Nonexistent
stake IDs revert in RAILGUN's stake lookup.

## qRAIL

`qRAIL` is an ERC20 representation of queued RAIL principal.

``` text
Name: Queued RAIL
Symbol: qRAIL
Decimals: same as RAIL
1 qRAIL = claim on 1 RAIL principal
```

Recommended:

``` solidity
contract QueuedRail is ERC20, AccessControl
```

Roles:

``` text
MINTER_ROLE -> RailStakePositionManager
BURNER_ROLE -> PositionManager / authorized exit component
```

qRAIL may only be minted after an actual RAILGUN position successfully
enters unstaking.

Backing invariant:

``` text
qRAIL.totalSupply()
<= queued/claimable principal
 + RAIL explicitly escrowed as qRAIL backing
```

Prefer exact equality outside atomic transitions.

## Queueing a Stake

``` solidity
function queuePosition(uint256 stakeId)
    external
    onlyRole(KEEPER_ROLE)
    returns (uint256 qRailMinted);
```

Required ordering:

1.  Verify stake exists and is ACTIVE.
2.  Determine its principal.
3.  Successfully initiate external unstaking.
4.  Mark the position UNSTAKING.
5.  Decrease `activePrincipal`.
6.  Increase `queuedPrincipal`.
7.  Mint qRAIL equal to principal.

The external unstake must succeed before qRAIL is minted. A position
cannot mint qRAIL twice.

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

## RailWithdrawalResolver

Implement:

``` solidity
contract RailWithdrawalResolver
```

Grant:

``` text
WithdrawalRequest.RESOLVER_ROLE -> RailWithdrawalResolver
```

Responsibilities:

-   enforce request ordering;
-   determine aggregate withdrawal demand;
-   allocate qRAIL;
-   trigger unstaking;
-   claim matured positions;
-   resolve requests into RAIL;
-   enforce cancellation policy.

V1 should use **strict FIFO and full fills**.

``` text
request N+1 must not consume liquidity
required to fully satisfy unresolved request N
```

Bound keeper work with separate calls:

``` solidity
function allocateRequests(uint256 maxRequests) external;
function claimMaturedPositions(uint256[] calldata stakeIds) external;
function resolveRequests(uint256 maxRequests) external;
```

## Rebalancing

Staking keeper:

``` solidity
function rebalanceStaking(uint256 maxOperations)
```

It creates full stake chunks and leaves only a sub-chunk remainder when
the operation limit permits staking all available chunks.

The exit processor queues complete stake positions before minting the
corresponding qRAIL to stRAIL. It then redeems the user's stRAIL shares
for qRAIL, which the user can submit to the withdrawal queue.

Excess qRAIL from whole-position exits remains in stRAIL for later exits.
No separate exit rebalancing is needed: withdrawal requests already hold
backed qRAIL. The resolver only claims matured positions into qRAIL and
resolves requests in FIFO order as RAIL becomes available.

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
  KEEPER_ROLE
  PAUSER_ROLE

qRAIL:
  DEFAULT_ADMIN_ROLE
  MINTER_ROLE
  BURNER_ROLE

WithdrawalRequest:
  existing roles
  RESOLVER_ROLE -> RailWithdrawalResolver
```

The resolver module, rather than a normal keeper EOA, should hold
settlement authority.

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

The current deployment script does not yet perform this handoff.

## Emergency Behavior

Use independent pause domains:

1.  Deposit pause: stop new stRAIL deposits.
2.  Stake pause: stop new RAILGUN stakes while permitting matured
    claims.
3.  Request pause: stop new requests while permitting existing request
    resolution.

Emergency pausing should not unnecessarily prevent matured RAIL claims
or settlement of existing requests.

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

1.  qRAIL supply never exceeds queued backing.
2.  Reserved qRAIL never exceeds qRAIL controlled by the exit system.
3.  Active plus queued principal reconciles to external non-claimed
    positions.
4.  A position cannot be ACTIVE and UNSTAKING simultaneously.
5.  A stake ID cannot mint qRAIL twice.
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
activePrincipal -= 25,000
queuedPrincipal += 25,000
qRAIL minted     = 25,000
```

Alice receives a 10,000 qRAIL reservation. The remaining 15,000 qRAIL
stays unreserved for later requests.

When the position matures, 25,000 RAIL is claimed and the corresponding
qRAIL backing is reconciled/burned. Alice's 10,000 RAIL becomes reserved
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
RailWithdrawalResolver
StakedRailViewer
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
positional exit lifecycle. YieldNest's `BaseWithdrawer` and `RailWithdrawalResolver`
bridge that internal liquidity state into the existing YieldNest
withdrawal-request system.

This keeps the implementation small, auditable and aligned with the
existing YieldNest architecture.
