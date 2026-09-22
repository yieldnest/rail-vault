// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {RailStrategyDeployer} from "./RailStrategyDeployer.sol";

contract DeployStakedRail is Script {
    function run() external {
        RailStrategyDeployer.Config memory config = RailStrategyDeployer.Config({
            admin: vm.envOr("ADMIN", msg.sender),
            rail: vm.envAddress("RAIL"),
            staking: vm.envAddress("RAIL_STAKING"),
            governorRewards: vm.envAddress("GOVERNOR_REWARDS"),
            rewardTokens: vm.envAddress("REWARD_TOKENS", ","),
            nextRewardClaimInterval: vm.envUint("NEXT_REWARD_CLAIM_INTERVAL"),
            stakeChunkSize: vm.envOr("STAKE_CHUNK_SIZE", uint256(1000 ether)),
            unpause: vm.envOr("UNPAUSE", false)
        });
        vm.startBroadcast();

        RailStrategyDeployer deployer = new RailStrategyDeployer(config);
        RailStrategyDeployer.Deployed memory deployed = deployer.deploy();

        vm.stopBroadcast();

        string memory json = "staked-rail";
        vm.serializeAddress(json, "deployer", address(deployer));
        vm.serializeAddress(json, "qRail", address(deployed.qRail));
        vm.serializeAddress(json, "positionManager", address(deployed.manager));
        vm.serializeAddress(json, "activeRail", address(deployed.manager.activeRail()));
        vm.serializeAddress(json, "unlockedRail", address(deployed.manager.unlockedRail()));
        vm.serializeAddress(json, "bagFactory", address(deployed.bagFactory));
        vm.serializeAddress(json, "withdrawalRequest", address(deployed.withdrawalRequest));
        vm.serializeAddress(json, "withdrawer", address(deployed.withdrawer));
        vm.serializeAddress(json, "resolver", address(deployed.resolver));
        vm.serializeAddress(json, "processor", address(deployed.processor));
        vm.serializeAddress(json, "queuedRailProcessor", address(deployed.queuedRailProcessor));
        vm.serializeAddress(json, "rewardsProcessor", address(deployed.rewardsProcessor));
        string memory output = vm.serializeAddress(json, "strategy", address(deployed.strategy));
        vm.writeJson(output, string.concat("deployments/staked-rail-", vm.toString(block.chainid), ".json"));
    }
}
