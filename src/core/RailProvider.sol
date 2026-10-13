// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IProvider} from "@yieldnest-vault/interface/IProvider.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract RailProvider is IProvider, Initializable {
    error UnsupportedAsset(address asset);

    address public rail;
    address public queuedRail;
    address public activeRail;
    address public unlockedRail;
    uint256 public rate;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address railAddress,
        address activeRailAddress,
        address unlockedRailAddress,
        address queuedRailAddress
    ) external initializer {
        rail = railAddress;
        queuedRail = queuedRailAddress;
        activeRail = activeRailAddress;
        unlockedRail = unlockedRailAddress;
        rate = 10 ** IERC20Metadata(railAddress).decimals();
    }

    function getRate(address asset) external view returns (uint256) {
        if (asset != address(0) && (asset == rail || asset == activeRail || asset == unlockedRail)) return rate;
        if (asset == queuedRail && queuedRail != address(0)) {
            // Critical: this quote is used to convert RAIL value into qRAIL on stRAIL exits.
            // previewMint rounds up; convertToAssets rounds down and can understate the qRAIL
            // rate, causing exits to issue excess qRAIL that redeems for more RAIL than deposited.
            return IERC4626(queuedRail).previewMint(10 ** IERC20Metadata(queuedRail).decimals());
        }
        revert UnsupportedAsset(asset);
    }
}
