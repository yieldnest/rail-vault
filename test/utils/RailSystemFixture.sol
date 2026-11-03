// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RailStrategyDeployer} from "../../script/RailStrategyDeployer.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRailgunStaking} from "../mocks/MockRailgunStaking.sol";
import {MockSplitsSwapper} from "../mocks/MockSplitsSwapper.sol";

/// @dev Uses production deployment wiring. Tests bootstrap both vaults before public activity.
abstract contract RailSystemFixture is Test {
    MockERC20 internal rail;
    MockRailgunStaking internal staking;
    MockSplitsSwapper internal splits;
    RailStrategyDeployer.Deployed internal d;
    address internal bootstrap = makeAddr("lockedBootstrap");
    address internal rewardReceiver = makeAddr("rewardReceiver");

    function _deploySystem() internal {
        rail = new MockERC20("RAIL", "RAIL", 18);
        staking = new MockRailgunStaking(rail);
        splits = new MockSplitsSwapper(rewardReceiver, address(rail));
        RailStrategyDeployer deployer = new RailStrategyDeployer(
            RailStrategyDeployer.Config({
                admin: address(this),
                pauser: address(this),
                unpauser: address(this),
                rail: address(rail),
                staking: address(staking),
                splitsSwapper: address(splits),
                stakeChunkSize: 1000 ether,
                unpause: true
            })
        );
        d = deployer.deploy();
    }

    function _deposit(address actor, uint256 amount) internal returns (uint256 shares) {
        rail.mint(actor, amount);
        vm.startPrank(actor);
        rail.approve(address(d.strategy), amount);
        shares = d.strategy.deposit(amount, actor);
        vm.stopPrank();
    }

    function _exit(address actor, uint256 shares, uint256 maxPositions) internal returns (uint256 assets) {
        vm.startPrank(actor);
        d.strategy.approve(address(d.processor), shares);
        assets = d.processor.exitToQueuedRail(shares, actor, maxPositions);
        vm.stopPrank();
    }

    function _bootstrapSystem() internal {
        _deposit(bootstrap, 10_000 ether);
        d.processor.rebalanceStaking(10);
        _exit(bootstrap, 2000 ether, 2);
    }
}
