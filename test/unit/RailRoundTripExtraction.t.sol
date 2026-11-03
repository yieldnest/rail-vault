// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVault} from "@yieldnest-vault/interface/IVault.sol";
import {StakedRailStrategy} from "../../src/core/StakedRailStrategy.sol";
import {StakedRailProcessor} from "../../src/processors/StakedRailProcessor.sol";
import {RailSystemFixture} from "../utils/RailSystemFixture.sol";

/// @dev Entry, optional attacker-funded donations, and exit happen in one external call.
/// A failed exit therefore also rolls back the entry and donations.
contract AtomicRailTrader {
    StakedRailStrategy public immutable strategy;
    StakedRailProcessor public immutable processor;
    IERC20 public immutable rail;

    constructor(StakedRailStrategy strategy_, StakedRailProcessor processor_, IERC20 rail_) {
        strategy = strategy_;
        processor = processor_;
        rail = rail_;
        rail.approve(address(strategy_), type(uint256).max);
        strategy.approve(address(processor_), type(uint256).max);
    }

    function roundTrip(uint256 amount, bool mintShares, uint256 stDonation, uint256 qDonation, bool refreshAccounting)
        external
        returns (uint256 spent, uint256 received)
    {
        uint256 beforeBalance = rail.balanceOf(address(this));
        uint256 shares;
        if (mintShares) {
            strategy.mint(amount, address(this));
            shares = amount;
        } else {
            shares = strategy.deposit(amount, address(this));
        }
        if (stDonation != 0) rail.transfer(address(strategy), stDonation);
        if (qDonation != 0) rail.transfer(address(strategy.queuedRail()), qDonation);
        if (refreshAccounting) strategy.processAccounting();
        received = processor.exitToQueuedRail(shares, address(this), 256);
        spent = beforeBalance - rail.balanceOf(address(this));
    }
}

/// forge-config: default.fuzz.runs = 1024
contract RailRoundTripExtractionTest is RailSystemFixture {
    AtomicRailTrader internal alice;
    AtomicRailTrader internal bob;

    struct Snapshot {
        uint256 wealth;
        uint256 actorRail;
        uint256 actorQ;
        uint256 qSupply;
        uint256 stSupply;
        uint256 qAssets;
        uint256 stAssets;
        uint256 activeCount;
    }

    function setUp() public {
        _deploySystem();
        alice = new AtomicRailTrader(d.strategy, d.processor, rail);
        bob = new AtomicRailTrader(d.strategy, d.processor, rail);
    }

    function testFuzzDepositThenExitAfterArbitraryDonations(
        uint256 chunkSeed,
        uint256 stDonationSeed,
        uint256 qDonationSeed,
        uint256 budgetSeed,
        uint64 feeSeed
    ) external {
        uint256 chunk = _seedScenario(chunkSeed, stDonationSeed, qDonationSeed, feeSeed);
        _checkRoundTrip(alice, bound(budgetSeed, 1, chunk), false, 0, 0);
    }

    function testFuzzMintThenExitAfterArbitraryDonations(
        uint256 chunkSeed,
        uint256 stDonationSeed,
        uint256 qDonationSeed,
        uint256 budgetSeed,
        uint64 feeSeed
    ) external {
        uint256 chunk = _seedScenario(chunkSeed, stDonationSeed, qDonationSeed, feeSeed);
        _checkRoundTrip(alice, bound(budgetSeed, 1, chunk), true, 0, 0);
    }

    function testFuzzRepeatedTwoActorRoundTripsWithDonationManipulation(uint256 seed, uint8 roundsSeed) external {
        uint256 chunk = _seedScenario(_random(seed, 0), _random(seed, 1), _random(seed, 2), _random(seed, 3));
        uint256 rounds = bound(uint256(roundsSeed), 2, 6);
        for (uint256 i; i < rounds; ++i) {
            // Independent donations are included in the next entry price, not counted as attacker profit.
            rail.mint(address(d.strategy), bound(_random(seed, 10 + i), 0, chunk));
            rail.mint(address(d.qRail), bound(_random(seed, 20 + i), 0, chunk));
            d.processor.rebalanceStaking(8);
            d.strategy.setBaseWithdrawalFee(uint64(bound(_random(seed, 30 + i), 0, 10_000_000)));
            _checkRoundTrip(
                i % 2 == 0 ? alice : bob,
                bound(_random(seed, 40 + i), 1, chunk),
                i % 2 != 0,
                bound(_random(seed, 50 + i), 0, chunk),
                bound(_random(seed, 60 + i), 0, chunk)
            );
        }
    }

    function testTinyAmountsAndChunkBoundaries() external {
        _seedScenario(1000 ether + 7, 137 ether + 3, 293 ether + 11, 0);
        uint256[6] memory amounts = [uint256(1), 2, 3, 1000 ether + 6, 1000 ether + 7, 1000 ether + 8];
        uint256 successes;
        for (uint256 i; i < amounts.length; ++i) {
            if (_checkRoundTrip(i % 2 == 0 ? alice : bob, amounts[i], i % 2 != 0, 0, 0)) successes++;
        }
        assertGe(successes, 3, "chunk-boundary exits must actually execute");
    }

    function testRepeatedEntriesExecuteWithFeesAndAttackerFundedDonations() external {
        _seedScenario(1000 ether + 7, 137 ether + 3, 293 ether + 11, 1_000_000);
        for (uint256 i; i < 6; ++i) {
            assertTrue(
                _checkRoundTrip(i % 2 == 0 ? alice : bob, 100 ether + i, i % 2 != 0, 1 ether + i, 2 ether + i),
                "non-dust round trip unexpectedly rejected"
            );
        }
    }

    function testHarnessDetectsCachedAccountingExtraction() external {
        _seedScenario(1000 ether, 0, 0, 0);
        d.strategy.grantRole(d.strategy.ASSET_MANAGER_ROLE(), address(this));
        d.strategy.setAlwaysComputeTotalAssets(false);
        rail.mint(address(d.strategy), 1000 ether);
        rail.mint(address(alice), 1000 ether);
        (uint256 spent, uint256 received) = alice.roundTrip(1000 ether, false, 0, 0, true);
        assertEq(spent, 1000 ether);
        assertGt(d.qRail.convertToAssets(received), spent, "positive control must detect extraction");
    }

    function _seedScenario(uint256 chunkSeed, uint256 stDonationSeed, uint256 qDonationSeed, uint256 feeSeed)
        internal
        returns (uint256 chunk)
    {
        // Include wei-sized bootstraps, not just whole-token and production-sized inputs.
        chunk = bound(chunkSeed, 1, 1000 ether + 7);
        d.processor.setStakeChunkSize(chunk);
        _deposit(bootstrap, chunk * 10);
        d.processor.rebalanceStaking(10);
        _exit(bootstrap, chunk * 2, 2);
        rail.mint(address(d.strategy), bound(stDonationSeed, 0, chunk * 1000));
        rail.mint(address(d.qRail), bound(qDonationSeed, 0, chunk * 1000));
        d.strategy.setBaseWithdrawalFee(uint64(bound(feeSeed, 0, 10_000_000)));
        assertTrue(d.strategy.alwaysComputeTotalAssets());
        assertTrue(d.qRail.alwaysComputeTotalAssets());
    }

    function _checkRoundTrip(
        AtomicRailTrader actor,
        uint256 budget,
        bool mintShares,
        uint256 stDonation,
        uint256 qDonation
    ) internal returns (bool) {
        uint256 amount = budget;
        uint256 entryCost = budget;
        if (mintShares) {
            amount = d.strategy.previewDeposit(budget);
            if (amount == 0) amount = 1;
            entryCost = d.strategy.previewMint(amount);
        }
        rail.mint(address(actor), entryCost + stDonation + qDonation);
        Snapshot memory before_ = _snapshot(address(actor));
        try actor.roundTrip(amount, mintShares, stDonation, qDonation, false) returns (
            uint256 spent, uint256 received
        ) {
            assertEq(spent, entryCost + stDonation + qDonation);
            assertEq(d.strategy.balanceOf(address(actor)), 0);
            assertEq(d.qRail.balanceOf(address(actor)) - before_.actorQ, received);
            // Freshly acquired claims cannot redeem for more than entry and manipulation cost.
            assertLe(d.qRail.convertToAssets(received), spent, "fresh entry extracted principal");
            uint256 queued = before_.activeCount - d.manager.activePositionCount();
            // Existing qRAIL holders can receive mint-rounding dust when a whole position
            // is deposited. Each deposit loses <1 qRAIL base unit to rounding. Use the
            // final (nondecreasing) price as a bound, plus one wei for valuation rounding.
            uint256 roundingBudget = queued * d.qRail.previewMint(1) + 1;
            assertLe(_wealth(), before_.wealth + roundingBudget, "coalition gain exceeds mint-rounding dust");
            return true;
        } catch (bytes memory reason) {
            _assertExpectedRejection(reason);
            assertEq(rail.balanceOf(address(actor)), before_.actorRail, "failed entry spent RAIL");
            assertEq(d.strategy.balanceOf(address(actor)), 0, "failed exit retained newly minted stRAIL");
            assertEq(d.qRail.balanceOf(address(actor)), before_.actorQ);
            assertEq(d.qRail.totalSupply(), before_.qSupply);
            assertEq(d.strategy.totalSupply(), before_.stSupply);
            assertEq(d.qRail.totalAssets(), before_.qAssets);
            assertEq(d.strategy.totalAssets(), before_.stAssets);
            assertEq(d.manager.activePositionCount(), before_.activeCount);
            assertEq(_wealth(), before_.wealth);
            return false;
        }
    }

    function _assertExpectedRejection(bytes memory reason) internal pure {
        bytes4 selector = bytes4(reason);
        if (selector == IVault.ProcessFailed.selector) {
            // A tiny bootstrap plus a large donation can make a queued chunk mint zero shares.
            bytes memory payload = new bytes(reason.length - 4);
            for (uint256 i; i < payload.length; ++i) {
                payload[i] = reason[i + 4];
            }
            (bytes memory callData, bytes memory inner) = abi.decode(payload, (bytes, bytes));
            require(bytes4(callData) == StakedRailStrategy.queuePosition.selector, "unexpected processor target");
            require(bytes4(inner) == StakedRailStrategy.ZeroQueuedShares.selector, "unexpected processor failure");
            return;
        }
        require(
            selector == IVault.ZeroAmount.selector || selector == IVault.ExceededMaxRedeem.selector
                || selector == StakedRailProcessor.ZeroShares.selector
                || selector == StakedRailProcessor.InsufficientQueuedRail.selector,
            "unexpected round-trip failure"
        );
    }

    function _snapshot(address actor) internal view returns (Snapshot memory s) {
        s.wealth = _wealth();
        s.actorRail = rail.balanceOf(actor);
        s.actorQ = d.qRail.balanceOf(actor);
        s.qSupply = d.qRail.totalSupply();
        s.stSupply = d.strategy.totalSupply();
        s.qAssets = d.qRail.totalAssets();
        s.stAssets = d.strategy.totalAssets();
        s.activeCount = d.manager.activePositionCount();
    }

    function _wealth() internal view returns (uint256) {
        return rail.balanceOf(address(alice)) + rail.balanceOf(address(bob))
            + d.qRail.convertToAssets(d.qRail.balanceOf(address(alice)) + d.qRail.balanceOf(address(bob)));
    }

    function _random(uint256 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }
}
