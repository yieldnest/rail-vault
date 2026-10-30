// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRailgunVoting {
    function STAKING_CONTRACT() external view returns (address);
    function VOTING_START_OFFSET() external view returns (uint256);
    function VOTING_YAY_END_OFFSET() external view returns (uint256);
    function VOTING_NAY_END_OFFSET() external view returns (uint256);
    function setVotingKey(address key) external;
    function votingKey(address account) external view returns (address);
    function vote(uint256 id, uint256 amount, bool affirmative, address account, uint256 hint) external;
    function proposals(uint256 id)
        external
        view
        returns (
            bool executed,
            address proposer,
            string memory document,
            uint256 publishTime,
            uint256 voteCallTime,
            uint256 sponsorship,
            uint256 yayVotes,
            uint256 nayVotes,
            uint256 sponsorInterval,
            uint256 votingInterval
        );
}

interface IRailgunVotingSnapshots {
    struct AccountSnapshot {
        uint256 interval;
        uint256 votingPower;
    }
    function DEPLOY_TIME() external view returns (uint256);
    function SNAPSHOT_INTERVAL() external view returns (uint256);
    function accountSnapshotAt(address account, uint256 interval, uint256 hint)
        external
        view
        returns (AccountSnapshot memory);
}
