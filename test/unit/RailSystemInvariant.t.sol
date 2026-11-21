// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBag} from "@yieldnest-vault-withdrawals/interface/IBag.sol";
import {WithdrawalRequest} from "@yieldnest-vault-withdrawals/WithdrawalRequest.sol";
import {RailStrategyDeployer} from "../../script/RailStrategyDeployer.sol";
import {StakedRailProcessor} from "../../src/processors/StakedRailProcessor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRailgunStaking} from "../mocks/MockRailgunStaking.sol";
import {RailSystemFixture} from "../utils/RailSystemFixture.sol";

/// @dev Three users, real deployment wiring, mock staking and already-claimed rewards.
/// Bootstrap shares stay untouched. No deal/storage edits, receipt minting or privileged
/// settlement: every lifecycle operation uses the deployed public entry points.
contract RailSystemHandler is Test {
    RailStrategyDeployer.Deployed internal d;
    MockERC20 public rail;
    MockERC20 public reward;
    MockRailgunStaking public staking;
    address public bootstrap;
    address public rewardReceiver;
    address[3] public actors;
    uint256 public railIssued;
    uint256 public railRewardsFunded;
    uint256 public requestsCreated;
    uint256 public exitsCompleted;
    uint256 public partialSettlements;
    uint256 public bagsClaimed;
    uint256 public rewardsCollected;
    mapping(uint256 => uint256) public railSettled;
    mapping(uint256 => uint256) public sharesSettled;
    mapping(uint256 => uint256) public railPaid;
    mapping(uint256 => uint256) public sharesPaid;

    constructor(
        RailStrategyDeployer.Deployed memory deployed,
        MockERC20 rail_,
        MockRailgunStaking staking_,
        address bootstrap_,
        address receiver_,
        address[3] memory actors_
    ) {
        d = deployed;
        rail = rail_;
        staking = staking_;
        bootstrap = bootstrap_;
        rewardReceiver = receiver_;
        actors = actors_;
        reward = new MockERC20("Reward", "RWD", 18);
        railIssued = rail.totalSupply();
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 amount = bound(amountSeed, 1, 10_000 ether);
        if (d.strategy.previewDeposit(amount) == 0) return;
        rail.mint(actor, amount);
        railIssued += amount;
        vm.startPrank(actor);
        rail.approve(address(d.strategy), amount);
        d.strategy.deposit(amount, actor);
        vm.stopPrank();
    }

    function stake(uint256 limitSeed) external {
        uint256 count = staking.stakesLength(address(d.manager));
        if (count >= 256) return;
        uint256 limit = bound(limitSeed, 1, 4);
        d.processor.rebalanceStaking(limit < 256 - count ? limit : 256 - count);
    }

    function exit(uint256 actorSeed, uint256 sharesSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 balance = d.strategy.balanceOf(actor);
        if (balance == 0) return;
        uint256 shares = bound(sharesSeed, 1, balance);
        // Dust can quote zero output and fail the vault's maxRedeem check when qRAIL liquidity is zero.
        if (d.strategy.previewRedeemAsset(address(d.qRail), shares) == 0) return;
        vm.startPrank(actor);
        d.strategy.approve(address(d.processor), shares);
        try d.processor.exitToQueuedRail(shares, actor, 256) returns (uint256) {
            exitsCompleted++;
        } catch (bytes memory reason) {
            // The documented idle-RAIL limitation is the only expected exit failure.
            assertEq(bytes4(reason), StakedRailProcessor.InsufficientQueuedRail.selector);
        }
        vm.stopPrank();
    }

    function request(uint256 actorSeed, uint256 sharesSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 balance = d.qRail.balanceOf(actor);
        if (balance < 100 ether || requestsCreated == 128) return;
        uint256 shares = bound(sharesSeed, 100 ether, balance);
        vm.startPrank(actor);
        d.qRail.approve(address(d.withdrawalRequest), shares);
        d.withdrawalRequest.requestWithdrawal(shares, actor);
        vm.stopPrank();
        requestsCreated++;
    }

    function donate(uint256 targetSeed, uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 1000 ether);
        rail.mint(targetSeed % 2 == 0 ? address(d.strategy) : address(d.qRail), amount);
        railIssued += amount;
    }

    function setFee(uint256 feeSeed) external {
        d.strategy.setBaseWithdrawalFee(uint64(bound(feeSeed, 0, 10_000_000))); // Up to 10%.
    }

    function elapse(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 45 days));
    }

    function claimPositions(uint256 limitSeed) external {
        uint256 limit = bound(limitSeed, 1, 16);
        uint256[] memory ids = new uint256[](limit);
        uint256 count;
        uint256 total = staking.stakesLength(address(d.manager));
        for (uint256 i; i < total && count < limit; ++i) {
            (,,, uint256 locktime, uint256 claimedTime) = staking.stakes(address(d.manager), i);
            if (claimedTime == 0 && locktime != 0 && block.timestamp > locktime) ids[count++] = i;
        }
        assembly ("memory-safe") { mstore(ids, count) }
        d.queuedRailProcessor.claimMaturedPositions(ids);
    }

    function resolve(uint256 limitSeed) external {
        uint256 total = d.withdrawalRequest.nextRequestId();
        uint256 previousHead = d.resolver.nextRequestToResolve();
        uint256[] memory locked = new uint256[](total);
        uint256[] memory rails = new uint256[](total);
        uint256[] memory shares = new uint256[](total);
        for (uint256 i; i < total; ++i) {
            WithdrawalRequest.Request memory r = d.withdrawalRequest.requests(i);
            locked[i] = r.amountLocked;
            rails[i] = rail.balanceOf(r.bag);
            shares[i] = d.qRail.balanceOf(r.bag);
        }
        d.resolver.resolveRequests(bound(limitSeed, 0, 8));
        uint256 head = d.resolver.nextRequestToResolve();
        assertGe(head, previousHead, "FIFO cursor went backwards");
        for (uint256 i; i < total; ++i) {
            WithdrawalRequest.Request memory r = d.withdrawalRequest.requests(i);
            uint256 received = rail.balanceOf(r.bag) - rails[i];
            uint256 residual = d.qRail.balanceOf(r.bag) - shares[i];
            railSettled[i] += received;
            sharesSettled[i] += residual;
            if (i > head) {
                assertEq(r.amountLocked, locked[i], "later request consumed shares");
                assertEq(received, 0, "later request consumed liquidity");
                assertEq(residual, 0, "later request received residual shares");
            }
            if (r.amountLocked != 0 && received != 0) partialSettlements++;
        }
    }

    function transferRequest(uint256 idSeed, uint256 actorSeed) external {
        if (requestsCreated == 0) return;
        uint256 id = idSeed % requestsCreated;
        address owner = d.withdrawalRequest.ownerOf(id);
        vm.prank(owner);
        d.withdrawalRequest.transferFrom(owner, actors[actorSeed % 3], id);
    }

    function claimBag(uint256 idSeed) external {
        if (requestsCreated == 0) return;
        uint256 id = idSeed % requestsCreated;
        address bag = d.withdrawalRequest.requests(id).bag;
        address owner = d.withdrawalRequest.ownerOf(id);
        address[] memory tokens = new address[](2);
        tokens[0] = address(rail);
        tokens[1] = address(d.qRail);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = rail.balanceOf(bag);
        amounts[1] = d.qRail.balanceOf(bag);
        if (amounts[0] == 0 && amounts[1] == 0) return;
        uint256 beforeRail = rail.balanceOf(owner);
        uint256 beforeShares = d.qRail.balanceOf(owner);
        vm.prank(owner);
        IBag(bag).claim(tokens, payable(owner), amounts);
        assertEq(rail.balanceOf(owner) - beforeRail, amounts[0]);
        assertEq(d.qRail.balanceOf(owner) - beforeShares, amounts[1]);
        railPaid[id] += amounts[0];
        sharesPaid[id] += amounts[1];
        bagsClaimed++;
    }

    function fundRewards(uint256 railSeed, uint256 rewardSeed) external {
        uint256 amount = bound(railSeed, 0, 1000 ether);
        rail.mint(address(d.manager), amount);
        railIssued += amount;
        railRewardsFunded += amount;
        reward.mint(address(d.manager), bound(rewardSeed, 0, 1000 ether));
    }

    function collectRewards() external {
        uint256 stAssets = d.strategy.totalAssets();
        uint256 qAssets = d.qRail.totalAssets();
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = rail;
        tokens[1] = reward;
        d.rewardsProcessor.collectTokens(tokens);
        // This deployment sends rewards outside both vaults: principal must be unchanged.
        assertEq(d.strategy.totalAssets(), stAssets);
        assertEq(d.qRail.totalAssets(), qAssets);
        rewardsCollected++;
    }

    function assertSystem() public view {
        uint256 active;
        uint256 queued;
        uint256 activeCount;
        uint256 total = staking.stakesLength(address(d.manager));
        for (uint256 i; i < total; ++i) {
            (, uint256 principal,, uint256 locktime, uint256 claimedTime) = staking.stakes(address(d.manager), i);
            if (claimedTime != 0) continue;
            if (locktime == 0) {
                active += principal;
                activeCount++;
            } else {
                queued += principal;
            }
        }
        assertEq(d.manager.activePositionCount(), activeCount);
        assertEq(d.manager.activeRail().totalSupply(), active);
        assertEq(d.manager.activeRail().balanceOf(address(d.strategy)), active);
        assertEq(d.manager.unlockedRail().totalSupply(), queued);
        assertEq(d.manager.unlockedRail().balanceOf(address(d.qRail)), queued);
        assertEq(rail.balanceOf(address(staking)), active + queued);
        uint256 qBacking = queued + rail.balanceOf(address(d.qRail));
        assertEq(d.qRail.totalAssets(), qBacking);
        // Independently reconcile stRAIL's configured valuation from physical backing and
        // the vault's virtual share/asset offsets, including the provider's upward unit quote.
        uint256 qRate = Math.mulDiv(1 ether, qBacking + 1, d.qRail.totalSupply() + 1, Math.Rounding.Ceil);
        assertEq(
            d.strategy.totalAssets(),
            rail.balanceOf(address(d.strategy)) + active
                + Math.mulDiv(d.qRail.balanceOf(address(d.strategy)), qRate, 1 ether)
        );
        assertEq(d.manager.activeRail().balanceOf(address(d.manager)), 0);
        assertEq(d.manager.unlockedRail().balanceOf(address(d.manager)), 0);

        uint256 stShares = d.strategy.balanceOf(bootstrap);
        uint256 qShares = d.qRail.balanceOf(bootstrap) + d.qRail.balanceOf(address(d.strategy))
            + d.qRail.balanceOf(address(d.withdrawalRequest));
        uint256 physicalRail = rail.balanceOf(bootstrap) + rail.balanceOf(address(staking))
            + rail.balanceOf(address(d.strategy)) + rail.balanceOf(address(d.qRail))
            + rail.balanceOf(address(d.manager)) + rail.balanceOf(rewardReceiver);
        for (uint256 i; i < 3; ++i) {
            stShares += d.strategy.balanceOf(actors[i]);
            qShares += d.qRail.balanceOf(actors[i]);
            physicalRail += rail.balanceOf(actors[i]);
        }
        uint256 locked;
        uint256 head = d.resolver.nextRequestToResolve();
        assertLe(head, requestsCreated);
        assertEq(d.withdrawalRequest.nextRequestId(), requestsCreated);
        for (uint256 i; i < requestsCreated; ++i) {
            WithdrawalRequest.Request memory r = d.withdrawalRequest.requests(i);
            if (i < head) assertEq(r.amountLocked, 0, "FIFO skipped an unsettled request");
            locked += r.amountLocked;
            uint256 bagRail = rail.balanceOf(r.bag);
            uint256 bagShares = d.qRail.balanceOf(r.bag);
            assertEq(bagRail + railPaid[i], railSettled[i], "request RAIL entitlement");
            assertEq(bagShares + sharesPaid[i], sharesSettled[i], "request residual entitlement");
            physicalRail += bagRail;
            qShares += bagShares;
        }
        assertEq(d.strategy.totalSupply(), stShares);
        assertEq(d.qRail.totalSupply(), qShares);
        assertEq(d.qRail.balanceOf(address(d.withdrawalRequest)), locked, "request shares double counted");
        assertEq(rail.totalSupply(), railIssued);
        assertEq(physicalRail, railIssued, "RAIL conservation across system");
        assertEq(rail.balanceOf(address(d.manager)) + rail.balanceOf(rewardReceiver), railRewardsFunded);
        assertEq(
            reward.totalSupply(),
            reward.balanceOf(address(d.manager)) + reward.balanceOf(d.rewardsProcessor.splitsSwapper())
        );
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract RailSystemInvariantTest is RailSystemFixture {
    RailSystemHandler internal handler;

    function setUp() public {
        _deploySystem();
        _bootstrapSystem();
        address[3] memory actors = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];
        for (uint256 i; i < 3; ++i) {
            _deposit(actors[i], 5000 ether);
        }
        d.processor.rebalanceStaking(15);
        handler = new RailSystemHandler(d, rail, staking, bootstrap, rewardReceiver, actors);
        d.strategy.grantRole(d.strategy.FEE_MANAGER_ROLE(), address(handler));
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.stake.selector;
        selectors[2] = handler.exit.selector;
        selectors[3] = handler.request.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.setFee.selector;
        selectors[6] = handler.elapse.selector;
        selectors[7] = handler.claimPositions.selector;
        selectors[8] = handler.resolve.selector;
        selectors[9] = handler.transferRequest.selector;
        selectors[10] = handler.claimBag.selector;
        selectors[11] = handler.fundRewards.selector;
        selectors[12] = handler.collectRewards.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        // Start with actual withdrawal demand and a partial fill, rather than empty queues.
        handler.exit(0, 2000 ether);
        handler.request(0, 1500 ether);
        handler.exit(1, 1000 ether);
        handler.request(1, 500 ether);
        handler.donate(1, 250 ether);
        handler.resolve(1);
    }

    function invariant_systemConservesBackingAndRequestEntitlements() public view {
        handler.assertSystem();
    }

    function testHandlerExercisesWholeLifecycle() external {
        handler.deposit(2, 1234 ether);
        handler.stake(2);
        handler.setFee(1_000_000);
        handler.exit(2, 500 ether);
        handler.elapse(31 days);
        handler.claimPositions(16);
        handler.resolve(8);
        handler.transferRequest(0, 2);
        handler.claimBag(0);
        handler.claimBag(1);
        handler.fundRewards(17 ether, 23 ether);
        handler.collectRewards();
        assertEq(handler.requestsCreated(), 2);
        assertEq(handler.exitsCompleted(), 3);
        assertGt(handler.partialSettlements(), 0);
        assertEq(handler.bagsClaimed(), 2);
        assertEq(handler.rewardsCollected(), 1);
        handler.assertSystem();
    }
}
