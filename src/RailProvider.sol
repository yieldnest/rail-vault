// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IProvider} from "@yieldnest-vault/interface/IProvider.sol";

contract RailProvider is IProvider {
    error UnsupportedAsset(address asset);

    address public immutable rail;
    address public immutable queuedRail;
    uint256 public immutable rate;

    constructor(address railAddress, address queuedRailAddress) {
        rail = railAddress;
        queuedRail = queuedRailAddress;
        rate = 10 ** IERC20Metadata(railAddress).decimals();
    }

    function getRate(address asset) external view returns (uint256) {
        if (asset != rail && asset != queuedRail) revert UnsupportedAsset(asset);
        return rate;
    }
}
