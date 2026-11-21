# stRAIL governance proposal

Status: draft for discussion. No option below is chosen yet.

## Premises

- **Supply cap.** stRAIL is capped at a maximum share of RAIL supply (for example 20–30%).
- **Yield is required.** RAILGUN staking rewards must flow to stRAIL holders.- **No voting from DeFi positions.** stRAIL held in Euler, Uniswap or other protocols cannot vote directly. Off the shelf, this is currently only possible with an off-chain system such as Snapshot, which can be used safely only for signalling and cannot translate the result into direct on-chain action.

## Background

- RAILGUN pays rewards by staked voting power at a snapshot every 14 days. Voting is not required to earn them.
- This gives holders a reason to put stRAIL in DeFi and not vote.
- RAILGUN quorum is a fixed 2M YES votes. RAIL that enters the vault and does not vote makes quorum harder to reach.

## Options

| # | Option | How the vault's voting power is used |
|---|---|---|
| 1 | No voting | stRAIL does not vote. The vault's power stays uncast. |
| 2 | Lock to vote | Holders lock stRAIL in a contract that mirrors RAIL governance and vote through it. |
| 3 | Delegates | A set of delegates votes with the stRAIL stake. |

## Diagrams

Contract names are the ones in this repo. Option 2 exists on `feature/governance-voting`. Option 3 is not built.

### Shared by all options: stake and rewards

```
 holder
   | deposit RAIL / receive stRAIL
   v
+---------------------+   RAIL    +--------------------------+
| stRAIL              |---------->| RailStakePositionManager |
| StakedRailStrategy  |           | (the staking account)    |
+---------------------+           +--------------------------+
   ^                                 | stake            ^
   | RAIL raises share price         v                  | claim, every 14 days
   |                              +----------+   +-----------------+
   |                              | RAILGUN  |   | RAILGUN         |
   |                              | Staking  |-->| GovernorRewards |
   |                              +----------+   +-----------------+
   |                               voting power snapshot
   |
+----------------------+  collectTokens  (from the position manager)
| RailRewardsProcessor |<-----------------------------------------
+----------------------+
   | other tokens
   v
 Splits Swapper --> swapped to RAIL --> stRAIL
```

Rewards depend on staked voting power only. They are the same under all three options.

### Option 1: no voting

```
+--------------------------+        +----------------+
| RailStakePositionManager |   X    | RAILGUN Voting |
| voting key: not set      |        |                |
+--------------------------+        +----------------+

 Vault power: never cast.
```

### Option 2: lock to vote

```
 holder
   | lock stRAIL                    stRAIL in Euler / Uniswap
   v                                (cannot lock, cannot vote)
+-------------------+  reads supply at snapshot  +----------------------+
| StakedRailVoting  |--------------------------->| StakedRailSupplyHook |
| (escrow)          |                            +----------------------+
+-------------------+
   | vote(proposal, yes/no, amount)
   | amount <= holder's share of the manager's snapshot power
   v
+----------------+  counted against  +--------------------------+
| RAILGUN Voting |------------------>| RailStakePositionManager |
+----------------+                   | voting key = escrow      |
                                     +--------------------------+

 Vault power: cast only for locked holders who vote. The rest stays uncast.
```

### Option 3: delegates

```
 stRAIL holders (anywhere, including DeFi)
   | appoint / remove, with a timelock
   v
+----------------------------+
| Delegate router (new)      |
| caps: delegate A <= x%     |
|       delegate B <= y% ... |
+----------------------------+
   ^                    | vote(proposal, yes/no, amount)
   | delegates A, B, C  v
   | call vote     +----------------+  counted against  +--------------------------+
                   | RAILGUN Voting |------------------>| RailStakePositionManager |
                   +----------------+                   | voting key = router      |
                                                        +--------------------------+

 Vault power: cast by delegates, up to their caps.
```

