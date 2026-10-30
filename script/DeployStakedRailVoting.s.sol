// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {StakedRailVoting} from "../src/governance/StakedRailVoting.sol";
import {StakedRailStrategy} from "../src/core/StakedRailStrategy.sol";
import {IRailgunVoting} from "../src/railgun/IRailgunVoting.sol";

/// @dev Run as the manager's DEFAULT_ADMIN_ROLE holder. No default addresses or lock policy.
contract DeployStakedRailVoting is Script {
    function run() external returns (StakedRailVoting escrow) {
        StakedRailStrategy strategy = StakedRailStrategy(payable(vm.envAddress("ST_RAIL")));
        IRailgunVoting voting = IRailgunVoting(vm.envAddress("RAILGUN_VOTING"));
        uint256 duration = vm.envUint("MINIMUM_LOCK_DURATION");
        vm.startBroadcast();
        strategy.checkpointTotalSupply();
        escrow = new StakedRailVoting(strategy, voting, duration);
        strategy.positionManager().setVotingKey(voting, address(escrow));
        vm.stopBroadcast();
    }
}
