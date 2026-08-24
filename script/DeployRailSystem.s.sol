// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IRailStaking} from "../src/interfaces/IRailStaking.sol";
import {RAILxVault} from "../src/RAILxVault.sol";
import {RailProvider} from "../src/RailProvider.sol";
import {RailStakingWithdrawer} from "../src/RailStakingWithdrawer.sol";
import {QueuedRailToken} from "../src/tokens/QueuedRailToken.sol";
import {RailWithdrawalNFT} from "../src/withdrawals/RailWithdrawalNFT.sol";

contract DeployRailSystem is Script {
    function run() external {
        address admin = vm.envOr("ADMIN", msg.sender);
        address rail = vm.envAddress("RAIL");
        address staking = vm.envAddress("RAIL_STAKING");
        bool unpause = vm.envOr("UNPAUSE", false);
        if (admin != msg.sender) revert AdminMustBeBroadcasterForInitialSetup();

        vm.startBroadcast();

        RailProvider provider = new RailProvider(rail);

        QueuedRailToken queuedRail = new QueuedRailToken(admin);

        RailStakingWithdrawer withdrawerImplementation = new RailStakingWithdrawer();
        RailStakingWithdrawer withdrawer = RailStakingWithdrawer(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(withdrawerImplementation),
                        admin,
                        abi.encodeCall(RailStakingWithdrawer.initialize, (admin, rail, IRailStaking(staking), queuedRail))
                    )
                )
            )
        );

        RailWithdrawalNFT withdrawalNFT = new RailWithdrawalNFT(admin, queuedRail, withdrawer);

        RAILxVault vaultImplementation = new RAILxVault();
        RAILxVault vault = RAILxVault(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(vaultImplementation),
                        admin,
                        abi.encodeCall(RAILxVault.initialize, (admin, rail, address(provider), withdrawalNFT))
                    )
                )
            )
        );

        _grantSetupRoles(vault, withdrawer, msg.sender);

        vault.setBuffer(address(withdrawer));
        queuedRail.grantRole(queuedRail.MINTER_ROLE(), address(withdrawer));
        queuedRail.grantRole(queuedRail.BURNER_ROLE(), address(withdrawer));
        withdrawalNFT.grantRole(withdrawalNFT.MINTER_ROLE(), address(vault));
        withdrawer.grantRole(withdrawer.PROCESSOR_ROLE(), admin);

        if (unpause) {
            withdrawer.unpause();
            vault.unpause();
        }

        vm.stopBroadcast();

        string memory json = "rail-system";
        vm.serializeAddress(json, "provider", address(provider));
        vm.serializeAddress(json, "withdrawer", address(withdrawer));
        vm.serializeAddress(json, "queuedRail", address(queuedRail));
        vm.serializeAddress(json, "withdrawalNFT", address(withdrawalNFT));
        string memory output = vm.serializeAddress(json, "vault", address(vault));
        vm.writeJson(output, string.concat("deployments/rail-system-", vm.toString(block.chainid), ".json"));
    }

    function _grantSetupRoles(RAILxVault vault, RailStakingWithdrawer withdrawer, address account) private {
        vault.grantRole(vault.BUFFER_MANAGER_ROLE(), account);
        vault.grantRole(vault.UNPAUSER_ROLE(), account);
        withdrawer.grantRole(withdrawer.UNPAUSER_ROLE(), account);
    }

    function _revokeSetupRoles(RAILxVault vault, RailStakingWithdrawer withdrawer, address account) private {
        vault.revokeRole(vault.BUFFER_MANAGER_ROLE(), account);
        vault.revokeRole(vault.UNPAUSER_ROLE(), account);
        withdrawer.revokeRole(withdrawer.UNPAUSER_ROLE(), account);
    }

    error AdminMustBeBroadcasterForInitialSetup();
}
