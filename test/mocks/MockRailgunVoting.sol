// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRailgunVotingSnapshots} from "../../src/railgun/IRailgunVoting.sol";

contract MockRailgunVoting {
    struct Proposal {
        bool executed;
        address proposer;
        string document;
        uint256 publishTime;
        uint256 voteCallTime;
        uint256 sponsorship;
        uint256 yayVotes;
        uint256 nayVotes;
        uint256 sponsorInterval;
        uint256 votingInterval;
    }
    address public immutable STAKING_CONTRACT;
    uint256 public constant VOTING_START_OFFSET = 2 days;
    uint256 public constant VOTING_YAY_END_OFFSET = 5 days;
    uint256 public constant VOTING_NAY_END_OFFSET = 6 days;
    mapping(address => address) public votingKey;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => uint256)) public getVotes;

    constructor(address staking) {
        STAKING_CONTRACT = staking;
    }

    function setVotingKey(address key) external {
        votingKey[msg.sender] = key;
    }

    function prepare(uint256 id, uint256 calledAt, uint256 interval) external {
        proposals[id].voteCallTime = calledAt;
        proposals[id].votingInterval = interval;
    }

    function vote(uint256 id, uint256 amount, bool affirmative, address account, uint256 hint) external {
        require(msg.sender == account || msg.sender == votingKey[account], "not voting key");
        Proposal storage p = proposals[id];
        require(block.timestamp > p.voteCallTime + VOTING_START_OFFSET, "not open");
        require(
            block.timestamp < p.voteCallTime + (affirmative ? VOTING_YAY_END_OFFSET : VOTING_NAY_END_OFFSET), "closed"
        );
        uint256 power =
            IRailgunVotingSnapshots(STAKING_CONTRACT).accountSnapshotAt(account, p.votingInterval, hint).votingPower;
        require(getVotes[id][account] + amount <= power, "over budget");
        getVotes[id][account] += amount;
        if (affirmative) p.yayVotes += amount;
        else p.nayVotes += amount;
    }
}
