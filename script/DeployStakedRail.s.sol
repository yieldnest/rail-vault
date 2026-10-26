// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {RailStrategyDeployer} from "./RailStrategyDeployer.sol";

contract DeployStakedRail is Script {
    function run() external {
        RailStrategyDeployer.Config memory config = RailStrategyDeployer.Config({
            admin: vm.envOr("ADMIN", msg.sender),
            rail: vm.envAddress("RAIL"),
            staking: vm.envAddress("RAIL_STAKING"),
            splitsSwapper: vm.envAddress("SPLITS_SWAPPER"),
            stakeChunkSize: vm.envOr("STAKE_CHUNK_SIZE", uint256(1000 ether)),
            unpause: vm.envOr("UNPAUSE", false)
        });
        vm.startBroadcast();

        RailStrategyDeployer deployer = new RailStrategyDeployer(config);
        RailStrategyDeployer.Deployed memory deployed = deployer.deploy();

        vm.stopBroadcast();

        // TODO: Bootstrap both vaults with an initial RAIL deposit, staking, qRAIL seeding
        // and permanently locked seed shares before opening the vaults to public deposits.
        console2.log("+------------------------------------------------------------------+");
        console2.log("| ATTENTION: VAULT CAPITAL BOOTSTRAP HAS NOT BEEN PERFORMED          |");
        console2.log("| Both vaults start empty. Seed stRAIL and qRAIL, and permanently    |");
        console2.log("| lock seed shares before opening public deposits.                 |");
        console2.log("| UNPAUSE=true does NOT perform this bootstrap.                     |");
        console2.log("+------------------------------------------------------------------+");

        string memory json = "staked-rail";
        vm.serializeAddress(json, "deployer", address(deployer));
        vm.serializeAddress(json, "qRail", address(deployed.qRail));
        vm.serializeAddress(json, "positionManager", address(deployed.manager));
        vm.serializeAddress(json, "activeRail", address(deployed.manager.activeRail()));
        vm.serializeAddress(json, "unlockedRail", address(deployed.manager.unlockedRail()));
        vm.serializeAddress(json, "bagFactory", address(deployed.bagFactory));
        vm.serializeAddress(json, "withdrawalRequest", address(deployed.withdrawalRequest));
        vm.serializeAddress(json, "requestPolicy", address(deployed.withdrawalRequest.requestPolicy()));
        vm.serializeAddress(json, "queuedRailProvider", deployed.qRail.provider());
        vm.serializeAddress(json, "stakedRailProvider", deployed.strategy.provider());
        vm.serializeAddress(json, "withdrawer", address(deployed.withdrawer));
        vm.serializeAddress(json, "resolver", address(deployed.resolver));
        vm.serializeAddress(json, "processor", address(deployed.processor));
        vm.serializeAddress(json, "queuedRailProcessor", address(deployed.queuedRailProcessor));
        vm.serializeAddress(json, "rewardsProcessor", address(deployed.rewardsProcessor));
        vm.serializeAddress(json, "splitsSwapper", deployed.rewardsProcessor.splitsSwapper());
        vm.serializeAddress(json, "railRewardReceiver", deployed.rewardsProcessor.railReceiver());
        string memory output = vm.serializeAddress(json, "strategy", address(deployed.strategy));
        vm.writeJson(output, string.concat("deployments/staked-rail-", vm.toString(block.chainid), ".json"));
    }
}
