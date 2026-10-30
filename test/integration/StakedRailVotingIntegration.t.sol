// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RailStrategyDeployer} from "../../script/RailStrategyDeployer.sol";
import {MockSplitsSwapper} from "../mocks/MockSplitsSwapper.sol";
import {StakedRailVoting} from "../../src/governance/StakedRailVoting.sol";
import {IRailgunVoting, IRailgunVotingSnapshots} from "../../src/railgun/IRailgunVoting.sol";
import {IRailgunStaking} from "../../src/railgun/IRailgunStaking.sol";

import {StakedRailSupplyHook} from "../../src/governance/StakedRailSupplyHook.sol";
import {IVault} from "@yieldnest-vault/interface/IVault.sol";

interface IRailgunProposalCreation {
    struct Call {
        address callContract;
        bytes data;
        uint256 value;
    }
    function createProposal(string calldata document, Call[] calldata calls) external returns (uint256);
    function sponsorProposal(uint256 id, uint256 amount, address account, uint256 hint) external;
    function callVote(uint256 id) external;
    function getVotes(uint256 id, address account) external view returns (uint256);
}

contract StakedRailVotingIntegrationTest is Test {
    IRailgunVoting constant voting = IRailgunVoting(0xc480F68A3dcC3EdD82134FAB45C14A0FcF1dA3CC);
    IRailgunStaking constant staking = IRailgunStaking(0xEE6A649Aa3766bD117e12C161726b693A1B2Ee20);
    event VoteCast(uint256 indexed id, address indexed voter, bool affirmative, uint256 votes);

    function testRealRailgunAcceptsShareholderVotesAndPreservesLocks() external {
        IERC20 rail = IERC20(staking.stakingToken());
        RailStrategyDeployer deployer = new RailStrategyDeployer(
            RailStrategyDeployer.Config({
                admin: address(this),
                pauser: address(this),
                unpauser: address(this),
                rail: address(rail),
                staking: address(staking),
                splitsSwapper: address(new MockSplitsSwapper(address(this), address(rail))),
                stakeChunkSize: 100_000 ether,
                unpause: true
            })
        );
        RailStrategyDeployer.Deployed memory d = deployer.deploy();
        StakedRailSupplyHook hook = new StakedRailSupplyHook(IVault(address(d.strategy)));
        d.strategy.grantRole(d.strategy.HOOKS_MANAGER_ROLE(), address(this));
        d.strategy.setHooks(address(hook));
        hook.checkpoint();
        StakedRailVoting escrow = new StakedRailVoting(d.strategy, voting, 7 days);
        d.manager.setVotingKey(voting, address(escrow));
        assertEq(voting.votingKey(address(d.manager)), address(escrow));

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        deal(address(rail), alice, 300_000 ether);
        deal(address(rail), bob, 700_000 ether);
        vm.startPrank(alice);
        rail.approve(address(d.strategy), 300_000 ether);
        d.strategy.deposit(300_000 ether, alice);
        d.strategy.approve(address(escrow), 300_000 ether);
        uint256 a = escrow.lock(300_000 ether, 10 days);
        vm.stopPrank();
        vm.startPrank(bob);
        rail.approve(address(d.strategy), 700_000 ether);
        d.strategy.deposit(700_000 ether, bob);
        d.strategy.approve(address(escrow), 700_000 ether);
        uint256 b = escrow.lock(700_000 ether, 10 days);
        vm.stopPrank();
        d.processor.rebalanceStaking(10);

        // Independent sponsor: the voting proxy does not expose arbitrary sponsorship calls.
        deal(address(rail), address(this), 500_000 ether);
        rail.approve(address(staking), 500_000 ether);
        staking.stake(500_000 ether);
        vm.warp(block.timestamp + 1 days + 1);
        IRailgunProposalCreation upstream = IRailgunProposalCreation(address(voting));
        IRailgunProposalCreation.Call[] memory actions = new IRailgunProposalCreation.Call[](1);
        actions[0] = IRailgunProposalCreation.Call(address(this), abi.encodeWithSignature("noop()"), 0);
        uint256 proposal = upstream.createProposal("stRAIL integration test only", actions);
        upstream.sponsorProposal(proposal, 500_000 ether, address(this), 0);
        upstream.callVote(proposal);
        vm.warp(block.timestamp + 2 days + 1);

        assertEq(escrow.votingPower(a, proposal, 0), 300_000 ether);
        assertEq(escrow.votingPower(b, proposal, 0), 700_000 ether);
        vm.expectEmit(true, true, false, true, address(voting));
        emit VoteCast(proposal, address(d.manager), true, 300_000 ether);
        vm.prank(alice);
        escrow.vote(a, proposal, 300_000 ether, true, 0);
        vm.expectEmit(true, true, false, true, address(voting));
        emit VoteCast(proposal, address(d.manager), false, 700_000 ether);
        vm.prank(bob);
        escrow.vote(b, proposal, 700_000 ether, false, 0);
        assertEq(upstream.getVotes(proposal, address(d.manager)), 1_000_000 ether);
        vm.startPrank(alice);
        vm.expectRevert(StakedRailVoting.InsufficientVotingPower.selector);
        escrow.vote(a, proposal, 1, true, 0);
        vm.expectRevert(StakedRailVoting.StillLocked.selector);
        escrow.withdraw(a);
        vm.warp(block.timestamp + 10 days);
        escrow.withdraw(a);
        vm.stopPrank();
        assertEq(d.strategy.balanceOf(alice), 300_000 ether);
    }
}
