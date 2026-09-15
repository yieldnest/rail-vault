// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {QueuedRail} from "../../src/QueuedRail.sol";
import {StakedRailStrategy} from "../../src/StakedRailStrategy.sol";
import {RailStakePositionManager} from "../../src/railgun/RailStakePositionManager.sol";
import {RailWithdrawalRequest} from "../../src/withdrawals/RailWithdrawalRequest.sol";
import {RailWithdrawer} from "../../src/withdrawals/RailWithdrawer.sol";
import {RailWithdrawalResolver} from "../../src/withdrawals/RailWithdrawalResolver.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRailgunStaking} from "../mocks/MockRailgunStaking.sol";

contract StakedRailStrategyTest is Test {
    address user = makeAddr("user");

    MockERC20 rail;
    MockRailgunStaking staking;
    QueuedRail qRail;
    RailStakePositionManager manager;
    StakedRailStrategy strategy;
    RailWithdrawalRequest requests;
    RailWithdrawer withdrawer;
    RailWithdrawalResolver resolver;

    function setUp() external {
        rail = new MockERC20("RAIL", "RAIL", 18);
        staking = new MockRailgunStaking(rail);
        qRail = new QueuedRail(address(this), address(rail));
        manager = new RailStakePositionManager(address(this), rail, staking, qRail);

        StakedRailStrategy implementation = new StakedRailStrategy();
        strategy = StakedRailStrategy(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(implementation),
                        makeAddr("proxyAdmin"),
                        abi.encodeCall(
                            StakedRailStrategy.initialize,
                            (address(this), address(rail), manager, 1000 ether, 1000 ether, 1000 ether, 100)
                        )
                    )
                )
            )
        );
        manager.setStrategy(address(strategy));

        requests = new RailWithdrawalRequest(address(this), strategy, rail);
        withdrawer = new RailWithdrawer(address(this), rail, qRail, requests);
        resolver = new RailWithdrawalResolver(address(this), strategy, manager, requests, withdrawer);

        qRail.grantRole(qRail.MINTER_ROLE(), address(manager));
        qRail.grantRole(qRail.BURNER_ROLE(), address(withdrawer));
        manager.setExitSystem(address(withdrawer));
        manager.grantRole(manager.KEEPER_ROLE(), address(resolver));
        strategy.grantRole(strategy.KEEPER_ROLE(), address(this));
        strategy.grantRole(strategy.WITHDRAWAL_REQUEST_ROLE(), address(requests));
        strategy.grantRole(strategy.UNPAUSER_ROLE(), address(this));
        requests.grantRole(requests.RESOLVER_ROLE(), address(resolver));
        withdrawer.grantRole(withdrawer.RESOLVER_ROLE(), address(resolver));
        resolver.grantRole(resolver.KEEPER_ROLE(), address(this));
        strategy.unpause();
    }

    function testDepositAndChunkedStakingAccounting() external {
        _deposit(user, 5000 ether);

        uint256 operations = strategy.rebalanceStaking(10);

        assertEq(operations, 4);
        assertEq(rail.balanceOf(address(strategy)), 1000 ether);
        assertEq(manager.activePrincipal(), 4000 ether);
        assertEq(manager.queuedPrincipal(), 0);
        assertEq(strategy.totalBaseAssets(), 5000 ether);
        assertEq(strategy.maxWithdraw(user), 0);
        assertEq(strategy.maxRedeem(user), 0);
    }

    function testFifoWithdrawalLifecycle() external {
        _deposit(user, 5000 ether);
        strategy.rebalanceStaking(10);

        vm.startPrank(user);
        strategy.approve(address(requests), 1500 ether);
        (uint256 requestId,) = requests.requestWithdrawal(1500 ether, user, "");
        vm.stopPrank();

        resolver.rebalanceExits(2);
        assertEq(qRail.balanceOf(address(withdrawer)), 2000 ether);
        assertEq(manager.activePrincipal(), 2000 ether);
        assertEq(manager.queuedPrincipal(), 2000 ether);

        resolver.allocateRequests(1);
        (uint256 shares, uint256 entitlement,,, RailWithdrawalRequest.RequestStatus status) =
            requests.requests(requestId);
        assertEq(shares, 1500 ether);
        assertEq(entitlement, 1500 ether);
        assertEq(uint256(status), uint256(RailWithdrawalRequest.RequestStatus.QUEUED));
        assertEq(withdrawer.totalReservedQRAIL(), 1500 ether);

        uint256[] memory stakeIds = manager.queuedStakeIdsList();
        vm.warp(block.timestamp + 30 days + 1);
        resolver.claimMaturedPositions(stakeIds);
        assertEq(rail.balanceOf(address(withdrawer)), 2000 ether);

        resolver.resolveRequests(1);
        (,,, address bag, RailWithdrawalRequest.RequestStatus resolvedStatus) = requests.requests(requestId);
        assertEq(uint256(resolvedStatus), uint256(RailWithdrawalRequest.RequestStatus.CLAIMABLE));
        assertEq(rail.balanceOf(bag), 1500 ether);
        assertEq(qRail.balanceOf(address(withdrawer)), 500 ether);

        vm.prank(user);
        requests.claim(requestId, user);
        assertEq(rail.balanceOf(user), 1500 ether);
    }

    function _deposit(address account, uint256 amount) internal {
        rail.mint(account, amount);
        vm.startPrank(account);
        rail.approve(address(strategy), amount);
        strategy.deposit(amount, account);
        vm.stopPrank();
    }
}
