// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {QueuedRail} from "../src/QueuedRail.sol";
import {StakedRailStrategy} from "../src/StakedRailStrategy.sol";
import {IRailgunStaking} from "../src/railgun/IRailgunStaking.sol";
import {RailStakePositionManager} from "../src/railgun/RailStakePositionManager.sol";
import {RailWithdrawalRequest} from "../src/withdrawals/RailWithdrawalRequest.sol";
import {RailWithdrawer} from "../src/withdrawals/RailWithdrawer.sol";
import {RailWithdrawalResolver} from "../src/withdrawals/RailWithdrawalResolver.sol";

contract DeployStakedRail is Script {
    struct Config {
        address admin;
        address rail;
        address staking;
        uint256 stakeChunkSize;
        uint256 minimumStakeAmount;
        uint256 targetIdleRail;
        uint256 maxActivePositions;
    }

    struct Deployed {
        QueuedRail qRail;
        RailStakePositionManager manager;
        StakedRailStrategy strategy;
        RailWithdrawalRequest withdrawalRequest;
        RailWithdrawer withdrawer;
        RailWithdrawalResolver resolver;
    }

    function run() external {
        Config memory config = Config({
            admin: vm.envOr("ADMIN", msg.sender),
            rail: vm.envAddress("RAIL"),
            staking: vm.envAddress("RAIL_STAKING"),
            stakeChunkSize: vm.envOr("STAKE_CHUNK_SIZE", uint256(1000 ether)),
            minimumStakeAmount: vm.envOr("MINIMUM_STAKE_AMOUNT", uint256(1000 ether)),
            targetIdleRail: vm.envOr("TARGET_IDLE_RAIL", uint256(1000 ether)),
            maxActivePositions: vm.envOr("MAX_ACTIVE_POSITIONS", uint256(1000))
        });
        if (config.admin != msg.sender) revert AdminMustBeBroadcasterForInitialSetup();

        bool unpause = vm.envOr("UNPAUSE", false);

        vm.startBroadcast();

        Deployed memory deployed = _deploy(config);
        _wire(config, deployed);

        if (unpause) {
            deployed.strategy.grantRole(deployed.strategy.UNPAUSER_ROLE(), config.admin);
            deployed.strategy.unpause();
        }

        vm.stopBroadcast();

        string memory json = "staked-rail";
        vm.serializeAddress(json, "qRail", address(deployed.qRail));
        vm.serializeAddress(json, "positionManager", address(deployed.manager));
        vm.serializeAddress(json, "withdrawalRequest", address(deployed.withdrawalRequest));
        vm.serializeAddress(json, "withdrawer", address(deployed.withdrawer));
        vm.serializeAddress(json, "resolver", address(deployed.resolver));
        string memory output = vm.serializeAddress(json, "strategy", address(deployed.strategy));
        vm.writeJson(output, string.concat("deployments/staked-rail-", vm.toString(block.chainid), ".json"));
    }

    function _deploy(Config memory config) private returns (Deployed memory deployed) {
        deployed.qRail = new QueuedRail(config.admin, config.rail);
        deployed.manager =
            new RailStakePositionManager(config.admin, IERC20(config.rail), IRailgunStaking(config.staking), deployed.qRail);

        StakedRailStrategy implementation = new StakedRailStrategy();
        deployed.strategy = StakedRailStrategy(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(implementation),
                        config.admin,
                        abi.encodeCall(
                            StakedRailStrategy.initialize,
                            (
                                config.admin,
                                config.rail,
                                deployed.manager,
                                config.stakeChunkSize,
                                config.minimumStakeAmount,
                                config.targetIdleRail,
                                config.maxActivePositions
                            )
                        )
                    )
                )
            )
        );

        deployed.withdrawalRequest = new RailWithdrawalRequest(config.admin, deployed.strategy, IERC20(config.rail));
        deployed.withdrawer = new RailWithdrawer(config.admin, IERC20(config.rail), deployed.qRail, deployed.withdrawalRequest);
        deployed.resolver =
            new RailWithdrawalResolver(config.admin, deployed.strategy, deployed.manager, deployed.withdrawalRequest, deployed.withdrawer);
    }

    function _wire(Config memory config, Deployed memory deployed) private {
        deployed.manager.setStrategy(address(deployed.strategy));
        deployed.manager.setExitSystem(address(deployed.withdrawer));
        deployed.qRail.grantRole(deployed.qRail.MINTER_ROLE(), address(deployed.manager));
        deployed.qRail.grantRole(deployed.qRail.BURNER_ROLE(), address(deployed.withdrawer));
        deployed.manager.grantRole(deployed.manager.KEEPER_ROLE(), address(deployed.resolver));
        deployed.strategy.grantRole(deployed.strategy.WITHDRAWAL_REQUEST_ROLE(), address(deployed.withdrawalRequest));
        deployed.withdrawalRequest.grantRole(deployed.withdrawalRequest.RESOLVER_ROLE(), address(deployed.resolver));
        deployed.withdrawer.grantRole(deployed.withdrawer.RESOLVER_ROLE(), address(deployed.resolver));
        deployed.resolver.grantRole(deployed.resolver.KEEPER_ROLE(), config.admin);
    }

    error AdminMustBeBroadcasterForInitialSetup();
}
