// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IProvider} from "@yieldnest-vault/interface/IProvider.sol";

contract RailProvider is IProvider {
    error UnsupportedAsset(address asset);

    address public immutable rail;
    address public immutable queuedRail;
    address public immutable activeRail;
    address public immutable unlockedRail;
    uint256 public immutable rate;

    constructor(
        address railAddress,
        address activeRailAddress,
        address unlockedRailAddress,
        address queuedRailAddress
    ) {
        rail = railAddress;
        queuedRail = queuedRailAddress;
        activeRail = activeRailAddress;
        unlockedRail = unlockedRailAddress;
        rate = 10 ** IERC20Metadata(railAddress).decimals();
    }

    function getRate(address asset) external view returns (uint256) {
        if (asset != address(0) && (asset == rail || asset == activeRail || asset == unlockedRail)) return rate;
        if (asset == queuedRail && queuedRail != address(0)) {
            return IERC4626(queuedRail).previewMint(10 ** IERC20Metadata(queuedRail).decimals());
        }
        revert UnsupportedAsset(asset);
    }
}
