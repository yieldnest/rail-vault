// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRailgunStaking {
    function STAKE_LOCKTIME() external view returns (uint256);
    function stakingToken() external view returns (address);
    function stake(uint256 amount) external returns (uint256 stakeId);
    function unlock(uint256 stakeId) external;
    function claim(uint256 stakeId) external;
    function stakesLength(address account) external view returns (uint256);

    function stakes(address account, uint256 stakeId)
        external
        view
        returns (address delegate, uint256 amount, uint256 staketime, uint256 locktime, uint256 claimedTime);
}
