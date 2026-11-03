// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {StakedRailVoting} from "../src/governance/StakedRailVoting.sol";
import {StakedRailStrategy} from "../src/core/StakedRailStrategy.sol";
import {IRailgunVoting} from "../src/railgun/IRailgunVoting.sol";
import {StakedRailSupplyHook} from "../src/governance/StakedRailSupplyHook.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IVault} from "@yieldnest-vault/interface/IVault.sol";

/// @dev Caller needs manager DEFAULT_ADMIN_ROLE and strategy HOOKS_MANAGER_ROLE.
contract DeployStakedRailVoting is Script {
    function run() external returns (StakedRailVoting escrow) {
        StakedRailStrategy strategy = StakedRailStrategy(payable(vm.envAddress("ST_RAIL")));
        IRailgunVoting voting = IRailgunVoting(vm.envAddress("RAILGUN_VOTING"));
        uint256 cooldown = vm.envUint("UNLOCK_COOLDOWN");
        require(address(strategy.hooks()) == address(0), "existing hooks require explicit migration");
        address proxyAdminOwner = vm.envAddress("HOOK_PROXY_ADMIN_OWNER");
        address votingProxyAdminOwner = vm.envAddress("VOTING_PROXY_ADMIN_OWNER");
        vm.startBroadcast();
        StakedRailSupplyHook hook = StakedRailSupplyHook(
            address(
                new TransparentUpgradeableProxy(
                    address(new StakedRailSupplyHook()),
                    proxyAdminOwner,
                    abi.encodeCall(StakedRailSupplyHook.initialize, (IVault(address(strategy))))
                )
            )
        );
        strategy.setHooks(address(hook));
        hook.checkpoint();
        escrow = StakedRailVoting(
            address(
                new TransparentUpgradeableProxy(
                    address(new StakedRailVoting()),
                    votingProxyAdminOwner,
                    abi.encodeCall(StakedRailVoting.initialize, (strategy, voting, hook, cooldown))
                )
            )
        );
        strategy.positionManager().setVotingKey(voting, address(escrow));
        vm.stopBroadcast();
    }
}
