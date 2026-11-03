// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRailgunStaking} from "../../src/railgun/IRailgunStaking.sol";

contract MockRailgunStaking is IRailgunStaking {
    using SafeERC20 for IERC20;

    struct Stake {
        address delegate;
        uint256 amount;
        uint256 staketime;
        uint256 locktime;
        uint256 claimedTime;
    }

    uint256 public constant override STAKE_LOCKTIME = 30 days;
    IERC20 public immutable rail;
    mapping(address => Stake[]) private accountStakes;

    constructor(IERC20 rail_) {
        rail = rail_;
    }

    function stakingToken() external view returns (address) {
        return address(rail);
    }

    function stake(uint256 amount) external returns (uint256 stakeId) {
        rail.safeTransferFrom(msg.sender, address(this), amount);
        stakeId = accountStakes[msg.sender].length;
        accountStakes[msg.sender].push(
            Stake({delegate: msg.sender, amount: amount, staketime: block.timestamp, locktime: 0, claimedTime: 0})
        );
    }

    function unlock(uint256 stakeId) external {
        Stake storage stake_ = accountStakes[msg.sender][stakeId];
        require(stake_.locktime == 0, "already unlocked");
        stake_.locktime = block.timestamp + STAKE_LOCKTIME;
    }

    function claim(uint256 stakeId) external {
        Stake storage stake_ = accountStakes[msg.sender][stakeId];
        require(stake_.locktime != 0 && block.timestamp > stake_.locktime, "not claimable");
        require(stake_.claimedTime == 0, "claimed");
        stake_.claimedTime = block.timestamp;
        rail.safeTransfer(msg.sender, stake_.amount);
    }

    function stakesLength(address account) external view returns (uint256) {
        return accountStakes[account].length;
    }

    function stakes(address account, uint256 stakeId)
        external
        view
        returns (address delegate, uint256 amount, uint256 staketime, uint256 locktime, uint256 claimedTime)
    {
        Stake storage stake_ = accountStakes[account][stakeId];
        return (stake_.delegate, stake_.amount, stake_.staketime, stake_.locktime, stake_.claimedTime);
    }
}
