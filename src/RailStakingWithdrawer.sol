// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata as IERC20, Math, SafeERC20} from "@yieldnest-vault/src/Common.sol";
import {BaseWithdrawer} from "@yieldnest-vault/src/withdraws/BaseWithdrawer.sol";
import {VaultLib} from "@yieldnest-vault/src/library/VaultLib.sol";

import {IRailStaking} from "./interfaces/IRailStaking.sol";
import {QueuedRailToken} from "./tokens/QueuedRailToken.sol";

contract RailStakingWithdrawer is BaseWithdrawer {
    using SafeERC20 for IERC20;

    string public constant RAIL_WITHDRAWER_VERSION = "0.1.0";

    IRailStaking public staking;
    QueuedRailToken public queuedRailToken;
    uint256[] private activeStakeIds;
    uint256[] private queuedStakeIds;

    event Staked(uint256 indexed stakeId, uint256 amount);
    event UnlockQueued(uint256 indexed stakeId, uint256 amount, address indexed queuedRailReceiver);
    event Claimed(uint256 indexed stakeId, uint256 amount);
    event QueuedRailRedeemed(address indexed receiver, uint256 amount);

    function initialize(address admin, address rail, IRailStaking staking_, QueuedRailToken queuedRailToken_)
        external
        initializer
    {
        staking = staking_;
        queuedRailToken = queuedRailToken_;
        _initialize(admin, "RAIL Staking Withdrawer", "ynRAILw", IERC20(rail).decimals(), true, false, true, 0);
        _addAsset(rail, IERC20(rail).decimals(), true);
        _setAssetWithdrawable(rail, true);
        VaultLib.setProvider(address(new RailLikeProvider(rail)));
        _setHasAllocator(true);
    }

    function stakeIdle(uint256 amount) external onlyRole(PROCESSOR_ROLE) returns (uint256 stakeId) {
        IERC20(asset()).forceApprove(address(staking), amount);
        stakeId = staking.stake(amount);
        activeStakeIds.push(stakeId);
        emit Staked(stakeId, amount);
    }

    function unlockStake(uint256 activeIndex, address queuedRailReceiver)
        external
        onlyRole(PROCESSOR_ROLE)
        returns (uint256 stakeId, uint256 amount)
    {
        stakeId = activeStakeIds[activeIndex];
        (, amount,,,) = staking.stakes(address(this), stakeId);
        _removeAt(activeStakeIds, activeIndex);
        queuedStakeIds.push(stakeId);
        staking.unlock(stakeId);
        queuedRailToken.mint(queuedRailReceiver, amount);
        emit UnlockQueued(stakeId, amount, queuedRailReceiver);
    }

    function claimUnlocked(uint256 queuedIndex) public onlyRole(PROCESSOR_ROLE) returns (uint256 stakeId, uint256 amount) {
        stakeId = queuedStakeIds[queuedIndex];
        (, amount,,,) = staking.stakes(address(this), stakeId);
        _removeAt(queuedStakeIds, queuedIndex);
        staking.claim(stakeId);
        emit Claimed(stakeId, amount);
    }

    function redeemQueuedRail(address receiver, uint256 amount) external returns (uint256 redeemed) {
        queuedRailToken.burn(msg.sender, amount);
        redeemed = _claimMaturedUntil(amount);
        IERC20(asset()).safeTransfer(receiver, redeemed);
        emit QueuedRailRedeemed(receiver, redeemed);
    }

    function asyncWithdrawalBalance(address asset_) public view override returns (uint256 baseAssets) {
        if (asset_ != asset()) return 0;
        return _convertAssetToBase(asset_, queuedRailBalance(), Math.Rounding.Floor);
    }

    function stakedRailBalance() public view returns (uint256 total) {
        total = _stakeIdsBalance(activeStakeIds);
    }

    function queuedRailBalance() public view returns (uint256 total) {
        total = _stakeIdsBalance(queuedStakeIds);
    }

    function activeStakes() external view returns (uint256[] memory) {
        return activeStakeIds;
    }

    function queuedStakes() external view returns (uint256[] memory) {
        return queuedStakeIds;
    }

    function totalBaseAssets() public view override returns (uint256) {
        return _computeRailTotalAssets();
    }

    function _processAccounting() internal override {
        uint256 totalBaseBalance = _computeRailTotalAssets();
        uint256 previousTotal = totalBaseAssets();
        VaultLib.getVaultStorage().totalAssets = totalBaseBalance;
        emit ProcessAccounting(block.timestamp, previousTotal, totalBaseBalance);
    }

    function _computeRailTotalAssets() internal view returns (uint256 totalBaseBalance) {
        totalBaseBalance = super.computeTotalAssets();
        totalBaseBalance += _convertAssetToBase(asset(), stakedRailBalance(), Math.Rounding.Floor);
    }

    function _claimMaturedUntil(uint256 amount) internal returns (uint256 redeemed) {
        uint256 i = 0;
        while (i < queuedStakeIds.length && redeemed < amount) {
            uint256 stakeId = queuedStakeIds[i];
            (, uint256 stakeAmount,, uint256 locktime,) = staking.stakes(address(this), stakeId);
            if (locktime == 0 || locktime >= block.timestamp) {
                i++;
                continue;
            }
            if (redeemed + stakeAmount > amount) revert PartialStakeClaimUnsupported();
            _removeAt(queuedStakeIds, i);
            staking.claim(stakeId);
            redeemed += stakeAmount;
            emit Claimed(stakeId, stakeAmount);
        }
        if (redeemed != amount) revert InsufficientMaturedRail(amount, redeemed);
    }

    function _stakeIdsBalance(uint256[] storage stakeIds) internal view returns (uint256 total) {
        for (uint256 i = 0; i < stakeIds.length; i++) {
            (, uint256 amount,,, uint256 claimedTime) = staking.stakes(address(this), stakeIds[i]);
            if (claimedTime == 0) total += amount;
        }
    }

    function _removeAt(uint256[] storage values, uint256 index) internal {
        values[index] = values[values.length - 1];
        values.pop();
    }

    error InsufficientMaturedRail(uint256 requested, uint256 available);
    error PartialStakeClaimUnsupported();
}

contract RailLikeProvider {
    error UnsupportedAsset(address asset);

    address public immutable rail;
    uint256 public immutable railRate;

    constructor(address rail_) {
        rail = rail_;
        railRate = 10 ** IERC20(rail_).decimals();
    }

    function getRate(address asset_) external view returns (uint256) {
        if (asset_ != rail) revert UnsupportedAsset(asset_);
        return railRate;
    }
}
