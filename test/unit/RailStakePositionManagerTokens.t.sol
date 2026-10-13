// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {RailManagerDeploymentLib} from "../../script/libraries/RailDeploymentLib.sol";

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RailStakePositionManager} from "../../src/core/RailStakePositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRailgunStaking} from "../mocks/MockRailgunStaking.sol";

contract CallbackRail is MockERC20 {
    RailStakePositionManager public manager;
    bool public armed;
    bool public callbackSucceeded;
    bytes public callbackResult;

    constructor() MockERC20("RAIL", "RAIL", 18) {}

    function arm(RailStakePositionManager manager_) external {
        manager = manager_;
        armed = true;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (armed && to == address(manager)) {
            armed = false;
            (callbackSucceeded, callbackResult) = address(manager)
                .call(
                    abi.encodeCall(
                        RailStakePositionManager.transferToken, (IERC20(address(this)), address(this), amount)
                    )
                );
        }
    }
}

contract RailStakePositionManagerTokensTest is Test {
    CallbackRail rail;
    MockRailgunStaking staking;
    RailStakePositionManager manager;
    address receiver = address(0xBEEF);

    function setUp() external {
        rail = new CallbackRail();
        staking = new MockRailgunStaking(rail);
        manager = RailManagerDeploymentLib.deploy(address(rail), address(staking), address(this));
        manager.grantRole(manager.TOKEN_WITHDRAWER_ROLE(), address(this));
        manager.grantRole(manager.TOKEN_WITHDRAWER_ROLE(), address(rail));
        manager.grantRole(manager.CREATOR_ROLE(), address(this));
        manager.grantRole(manager.QUEUER_ROLE(), address(this));
        manager.grantRole(manager.CLAIMER_ROLE(), address(this));
        rail.mint(address(this), 100 ether);
        rail.approve(address(manager), 100 ether);
    }

    function testTransferRequiresRole() external {
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", receiver, manager.TOKEN_WITHDRAWER_ROLE()
            )
        );
        vm.prank(receiver);
        manager.transferToken(rail, receiver, 0);
    }

    function testRejectsZeroAddresses() external {
        vm.expectRevert(RailStakePositionManager.ZeroAddress.selector);
        manager.transferToken(IERC20(address(0)), receiver, 0);
        vm.expectRevert(RailStakePositionManager.ZeroAddress.selector);
        manager.transferToken(rail, address(0), 0);
    }

    function testPartialTransferOfArbitraryToken() external {
        MockERC20 token = new MockERC20("Future Reward", "FUT", 6);
        token.mint(address(manager), 100e6);
        manager.transferToken(token, receiver, 40e6);
        assertEq(token.balanceOf(receiver), 40e6);
        assertEq(token.balanceOf(address(manager)), 60e6);
    }

    function testRailCollectionLeavesStakedAndQueuedPrincipalBacked() external {
        manager.createPosition(100 ether);
        rail.mint(address(manager), 7 ether);
        manager.transferToken(rail, receiver, 7 ether);
        assertEq(manager.activeRail().totalSupply(), 100 ether);
        assertEq(rail.balanceOf(address(staking)), 100 ether);
        manager.queuePosition();
        rail.mint(address(manager), 3 ether);
        manager.transferToken(rail, receiver, 3 ether);
        assertEq(manager.unlockedRail().totalSupply(), 100 ether);
        vm.warp(block.timestamp + 30 days + 1);
        manager.claimPosition(0, receiver);
        assertEq(rail.balanceOf(receiver), 110 ether);
        assertEq(manager.unlockedRail().totalSupply(), 0);
        assertEq(rail.balanceOf(address(manager)), 0);
    }

    function testCannotPullPrincipalDuringCreate() external {
        rail.arm(manager);
        manager.createPosition(100 ether);
        _assertCallbackBlocked();
        assertEq(rail.balanceOf(address(staking)), 100 ether);
        assertEq(manager.activeRail().totalSupply(), 100 ether);
    }

    function testCannotPullPrincipalDuringClaim() external {
        manager.createPosition(100 ether);
        manager.queuePosition();
        vm.warp(block.timestamp + 30 days + 1);
        rail.arm(manager);
        manager.claimPosition(0, receiver);
        _assertCallbackBlocked();
        assertEq(rail.balanceOf(receiver), 100 ether);
        assertEq(manager.unlockedRail().totalSupply(), 0);
    }

    function testBatchPrincipalClaimsStillWork() external {
        manager.createPosition(40 ether);
        manager.createPosition(60 ether);
        manager.queuePosition();
        manager.queuePosition();
        vm.warp(block.timestamp + 30 days + 1);
        uint256[] memory ids = new uint256[](2);
        ids[1] = 1;
        assertEq(manager.claimMaturedPositions(ids, receiver), 100 ether);
        assertEq(rail.balanceOf(receiver), 100 ether);
        assertEq(manager.unlockedRail().totalSupply(), 0);
    }

    function _assertCallbackBlocked() internal view {
        assertFalse(rail.armed());
        assertFalse(rail.callbackSucceeded());
        assertEq(rail.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }
}
