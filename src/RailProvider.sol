// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IProvider} from "@yieldnest-vault/src/interface/IProvider.sol";

contract RailProvider is IProvider {
    error UnsupportedAsset(address asset);

    address public immutable rail;
    uint256 public immutable railRate;

    constructor(address rail_) {
        rail = rail_;
        railRate = 10 ** IERC20Metadata(rail_).decimals();
    }

    function getRate(address asset) external view returns (uint256) {
        if (asset != rail) revert UnsupportedAsset(asset);
        return railRate;
    }
}
