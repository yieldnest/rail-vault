# stRAIL governance proposal

Status: draft for discussion. No option below is chosen yet.

## Premises

- **Supply cap.** stRAIL is capped at a maximum share of RAIL supply (for example 20–30%).
- **Yield is required.** RAILGUN staking rewards must flow to stRAIL holders. Without them, it would make more sense to boost markets for raw RAIL instead.
- **No voting from DeFi positions.** stRAIL held in Euler, Uniswap or other protocols cannot vote directly. No off-the-shelf system supports this.

## Background

- RAILGUN pays rewards by staked voting power at a snapshot every 14 days. Voting is not required to earn them.
- Rewards therefore reach every stRAIL holder through the share price, wherever the token sits.
- This gives holders a reason to put stRAIL in DeFi and not vote.
- RAILGUN quorum is a fixed 2M YES votes. RAIL that enters the vault and does not vote makes quorum harder to reach.

## Options

| # | Option | How the vault's voting power is used |
|---|---|---|
| 1 | No voting | stRAIL does not vote. The vault's power stays uncast. |
| 2 | Lock to vote | Holders lock stRAIL in a contract that mirrors RAIL governance and vote through it. |
| 3 | Delegates | A set of delegates votes with the stRAIL stake. |

## Trade-offs

| # | Advantage | Cost | Trust added |
|---|---|---|---|
| 1 | Simplest. Nothing to attack. | Up to the capped share of RAIL drops out of governance. | None |
| 2 | Holders decide. Already built on `feature/governance-voting`. | Locked stRAIL cannot be used in DeFi, so turnout is likely low. | The escrow's upgrade admin |
| 3 | Power is always cast, even when all stRAIL is in DeFi. | Delegates control up to 20–30% of supply, and RAILGUN votes cannot be undone. | The delegates, and whoever appoints them |

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

## Safeguards by option

**Option 1**
- Never set a RAILGUN voting key on the position manager, or remove the role that can set one.

**Option 2**
- Unvoted power stays uncast. Do not mirror it onto the voters.
- Put `setVotingKey` behind a timelock longer than one full vote (more than 6 days).
- Optional: pay voters a rebate from a fee on rewards, so that locking competes with DeFi yield.

**Option 3**
- Split the power across several delegates, with a cap per delegate.
- Let holders choose or remove delegates on-chain, with a timelock on changes.
- Use the RAILGUN voting key only. Never use `delegate()` on the stakes, because that moves the rewards to the delegatee.

## Open questions

1. What is the cap, and is it enforced in the contract or by policy?
2. For option 3, who appoints the delegates, and how are they removed?
3. Can options 2 and 3 be combined, so that locked holders vote directly and delegates vote only the remainder?
4. Should voters receive a rebate, and how large, given expected DeFi yields?
5. Would RAILGUN governance consider paying rewards by votes cast? `GovernorRewards` is written as an upgradeable contract, but this has not been confirmed on mainnet.
