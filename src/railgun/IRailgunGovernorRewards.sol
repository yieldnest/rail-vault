// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IRailgunGovernorRewards {
    function tokens(IERC20 token) external view returns (bool);
    function nextEarmarkInterval(IERC20 token) external view returns (uint256);

    function calculateRewards(
        IERC20[] calldata tokens,
        address account,
        uint256 startingInterval,
        uint256 endingInterval,
        uint256[] calldata hints,
        bool ignoreClaimed
    ) external view returns (uint256[] memory rewards);

    function claim(
        IERC20[] calldata tokens,
        address account,
        uint256 startingInterval,
        uint256 endingInterval,
        uint256[] calldata hints
    ) external;
}
