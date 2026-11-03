// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {RailManagerDeploymentLib} from "../../script/libraries/RailDeploymentLib.sol";

import {Test} from "forge-std/Test.sol";
import {RailStakePositionManager} from "../../src/core/RailStakePositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRailgunStaking} from "../mocks/MockRailgunStaking.sol";

/// @dev Only lifecycle actions are targeted. No rewards, donations, receipt transfers to the
/// manager, or transferToken calls (which could mask a retained balance by sweeping it).
contract PositionLifecycleHandler is Test {
    RailStakePositionManager public immutable manager;
    MockRailgunStaking public immutable staking;
    MockERC20 public immutable rail;

    uint256 public created;
    uint256 public claimed;
    uint256 public principalCreated;
    uint256 public principalReturned;
    uint256 public singleClaims;
    uint256 public batchClaims;

    constructor(RailStakePositionManager manager_, MockRailgunStaking staking_, MockERC20 rail_) {
        manager = manager_;
        staking = staking_;
        rail = rail_;
        rail.approve(address(manager), type(uint256).max);
    }

    function create(uint256 amountSeed) external {
        if (created == 128) return;
        uint256 amount = bound(amountSeed, 1, 1_000_000 ether);
        // Funding the caller is not a donation to the manager.
        rail.mint(address(this), amount);
        assertEq(manager.createPosition(amount), created);
        created++;
        principalCreated += amount;
        assertEmptyManager();
    }

    function queue() external {
        if (manager.activePositionCount() == 0) return;
        manager.queuePosition();
        assertEmptyManager();
    }

    function elapse(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 60 days));
    }

    function claimOne(uint256 positionSeed, uint256 receiverSeed) external {
        uint256[] memory ids = _maturedIds(positionSeed, 1);
        if (ids.length == 0) return;
        address receiver = _receiver(receiverSeed);
        uint256 beforeBalance = rail.balanceOf(receiver);
        uint256 amount = manager.claimPosition(ids[0], receiver);
        assertEq(rail.balanceOf(receiver) - beforeBalance, amount);
        claimed++;
        singleClaims++;
        principalReturned += amount;
        assertEmptyManager();
    }

    function claimBatch(uint256 positionSeed, uint256 countSeed, uint256 receiverSeed) external {
        uint256[] memory ids = _maturedIds(positionSeed, bound(countSeed, 1, 16));
        if (ids.length == 0) return;
        address receiver = _receiver(receiverSeed);
        uint256 beforeBalance = rail.balanceOf(receiver);
        uint256 amount = manager.claimMaturedPositions(ids, receiver);
        assertEq(rail.balanceOf(receiver) - beforeBalance, amount);
        claimed += ids.length;
        batchClaims++;
        principalReturned += amount;
        assertEmptyManager();
    }

    function assertEmptyManager() public view {
        assertEq(rail.balanceOf(address(manager)), 0, "manager retained RAIL");
        assertEq(manager.activeRail().balanceOf(address(manager)), 0, "manager retained aRAIL");
        assertEq(manager.unlockedRail().balanceOf(address(manager)), 0, "manager retained uRAIL");
    }

    function _maturedIds(uint256 seed, uint256 limit) internal view returns (uint256[] memory ids) {
        ids = new uint256[](limit);
        uint256 count;
        if (created != 0) {
            uint256 start = seed % created;
            for (uint256 i; i < created && count < limit; i++) {
                uint256 id = (start + i) % created;
                (,,, uint256 locktime, uint256 claimedTime) = staking.stakes(address(manager), id);
                if (manager.isClaimablePosition(locktime, claimedTime)) ids[count++] = id;
            }
        }
        assembly ("memory-safe") {
            mstore(ids, count)
        }
    }

    function _receiver(uint256 seed) internal pure returns (address) {
        // All receivers are external to the manager. Claiming to the manager itself is an
        // intentional token transfer and is outside this lifecycle-only invariant.
        return address(uint160(0xBEEF + seed % 4));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract RailStakePositionManagerInvariantTest is Test {
    MockERC20 internal rail;
    MockRailgunStaking internal staking;
    RailStakePositionManager internal manager;
    PositionLifecycleHandler internal handler;

    function setUp() public {
        rail = new MockERC20("RAIL", "RAIL", 18);
        staking = new MockRailgunStaking(rail);
        manager = RailManagerDeploymentLib.deploy(address(rail), address(staking), address(this));
        handler = new PositionLifecycleHandler(manager, staking, rail);
        manager.grantRole(manager.CREATOR_ROLE(), address(handler));
        manager.grantRole(manager.QUEUER_ROLE(), address(handler));
        manager.grantRole(manager.CLAIMER_ROLE(), address(handler));

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.queue.selector;
        selectors[2] = handler.elapse.selector;
        selectors[3] = handler.claimOne.selector;
        selectors[4] = handler.claimBatch.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        // Nonempty initial state avoids a vacuous zero-balance check. Keep both an active
        // and queued position so time advances and claims can act immediately.
        handler.create(1);
        handler.create(17 ether);
        handler.queue();
    }

    function invariant_lifecycleLeavesNoSweepableTokens() public view {
        // These are all tokens touched by the lifecycle. Arbitrary ERC-20s cannot arrive
        // through these actions; no claim of enumerating every ERC-20 on chain is made.
        handler.assertEmptyManager();
        uint256 outstanding = handler.principalCreated() - handler.principalReturned();
        assertEq(rail.balanceOf(address(staking)), outstanding, "principal conservation");
        assertEq(manager.activeRail().totalSupply() + manager.unlockedRail().totalSupply(), outstanding);
    }

    function afterInvariant() public {
        // Fully unwind every generated sequence, checking emptiness at each action boundary.
        while (manager.activePositionCount() != 0) handler.queue();
        handler.elapse(staking.STAKE_LOCKTIME() + 1);
        while (handler.claimed() < handler.created()) handler.claimBatch(0, 16, 0);
        invariant_lifecycleLeavesNoSweepableTokens();
        assertEq(handler.principalReturned(), handler.principalCreated());
        assertEq(manager.activeRail().totalSupply(), 0);
        assertEq(manager.unlockedRail().totalSupply(), 0);
    }

    function testLifecycleHandlerExercisesSingleAndBatchClaims() public {
        handler.create(33 ether);
        handler.create(49 ether);
        handler.queue();
        handler.queue();
        handler.queue();
        handler.elapse(staking.STAKE_LOCKTIME());
        handler.claimOne(2, 1); // Exactly at maturity: no claim yet.
        assertEq(handler.singleClaims(), 0);
        handler.elapse(1);
        handler.claimOne(2, 1); // Claim out of queue order.
        handler.claimBatch(3, 2, 2); // Wrap around the stake-id list.
        assertEq(handler.singleClaims(), 1);
        assertEq(handler.batchClaims(), 1);
        assertEq(handler.claimed(), 3);
        afterInvariant();
    }
}
