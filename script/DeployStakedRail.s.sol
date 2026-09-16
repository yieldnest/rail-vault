// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IVault} from "@yieldnest-vault/interface/IVault.sol";
import {IValidator} from "@yieldnest-vault/interface/IValidator.sol";
import {Bag} from "@yieldnest-vault-withdrawals/Bag.sol";
import {BeaconProxyFactory} from "@yieldnest-vault-withdrawals/BeaconProxyFactory.sol";
import {WithdrawalRequest} from "@yieldnest-vault-withdrawals/WithdrawalRequest.sol";
import {MinAmountRequestPolicy} from "@yieldnest-vault-withdrawals/policies/MinAmountRequestPolicy.sol";

import {QueuedRailStrategy} from "../src/QueuedRailStrategy.sol";
import {StakedRailStrategy} from "../src/StakedRailStrategy.sol";
import {StakedRailExitProcessor} from "../src/processors/StakedRailExitProcessor.sol";
import {StakedRailStakingProcessor} from "../src/processors/StakedRailStakingProcessor.sol";
import {IRailgunStaking} from "../src/railgun/IRailgunStaking.sol";
import {RailStakePositionManager} from "../src/railgun/RailStakePositionManager.sol";
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
        QueuedRailStrategy qRail;
        RailStakePositionManager manager;
        StakedRailStrategy strategy;
        BeaconProxyFactory bagFactory;
        WithdrawalRequest withdrawalRequest;
        RailWithdrawer withdrawer;
        RailWithdrawalResolver resolver;
        StakedRailStakingProcessor stakingProcessor;
        StakedRailExitProcessor exitProcessor;
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
        vm.serializeAddress(json, "bagFactory", address(deployed.bagFactory));
        vm.serializeAddress(json, "withdrawalRequest", address(deployed.withdrawalRequest));
        vm.serializeAddress(json, "withdrawer", address(deployed.withdrawer));
        vm.serializeAddress(json, "resolver", address(deployed.resolver));
        vm.serializeAddress(json, "stakingProcessor", address(deployed.stakingProcessor));
        vm.serializeAddress(json, "exitProcessor", address(deployed.exitProcessor));
        string memory output = vm.serializeAddress(json, "strategy", address(deployed.strategy));
        vm.writeJson(output, string.concat("deployments/staked-rail-", vm.toString(block.chainid), ".json"));
    }

    function _deploy(Config memory config) private returns (Deployed memory deployed) {
        QueuedRailStrategy qRailImplementation = new QueuedRailStrategy();
        deployed.qRail = QueuedRailStrategy(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(qRailImplementation),
                        config.admin,
                        abi.encodeCall(QueuedRailStrategy.initialize, (config.admin, config.rail))
                    )
                )
            )
        );

        deployed.manager =
            new RailStakePositionManager(config.admin, IERC20(config.rail), IRailgunStaking(config.staking));

        StakedRailStrategy strategyImplementation = new StakedRailStrategy();
        deployed.strategy = StakedRailStrategy(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(strategyImplementation),
                        config.admin,
                        abi.encodeCall(
                            StakedRailStrategy.initialize,
                            (config.admin, config.rail, deployed.manager)
                        )
                    )
                )
            )
        );

        Bag bagImplementation = new Bag();
        BeaconProxyFactory bagFactoryImplementation = new BeaconProxyFactory();
        deployed.bagFactory = BeaconProxyFactory(
            address(
                new TransparentUpgradeableProxy(
                    address(bagFactoryImplementation),
                    config.admin,
                    abi.encodeCall(
                        BeaconProxyFactory.initialize,
                        (address(bagImplementation), config.admin, config.admin, config.admin)
                    )
                )
            )
        );

        MinAmountRequestPolicy requestPolicy = new MinAmountRequestPolicy(1);
        WithdrawalRequest requestImplementation = new WithdrawalRequest();
        deployed.withdrawalRequest = WithdrawalRequest(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(requestImplementation),
                        config.admin,
                        abi.encodeCall(
                            WithdrawalRequest.initialize,
                            (
                                address(deployed.qRail),
                                config.admin,
                                config.admin,
                                config.admin,
                                config.admin,
                                address(deployed.bagFactory),
                                config.admin,
                                address(requestPolicy),
                                uint256(1024)
                            )
                        )
                    )
                )
            )
        );

        RailWithdrawer withdrawerImplementation = new RailWithdrawer();
        deployed.withdrawer = RailWithdrawer(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(withdrawerImplementation),
                        config.admin,
                        abi.encodeCall(
                            RailWithdrawer.initialize,
                            (address(deployed.qRail), address(deployed.withdrawalRequest), config.rail)
                        )
                    )
                )
            )
        );

        deployed.resolver =
            new RailWithdrawalResolver(config.admin, deployed.strategy, deployed.manager, deployed.withdrawalRequest, deployed.withdrawer);

        deployed.stakingProcessor = new StakedRailStakingProcessor(
            config.admin,
            deployed.strategy,
            deployed.manager,
            config.stakeChunkSize,
            config.minimumStakeAmount,
            config.targetIdleRail,
            config.maxActivePositions
        );
        deployed.exitProcessor = new StakedRailExitProcessor(deployed.strategy, deployed.qRail);
    }

    function _wire(Config memory config, Deployed memory deployed) private {
        deployed.manager.setStrategy(address(deployed.strategy));
        deployed.manager.setExitSystem(address(deployed.withdrawer));
        deployed.strategy.grantRole(deployed.strategy.PROCESSOR_ROLE(), address(deployed.stakingProcessor));
        deployed.strategy.grantRole(deployed.strategy.PROCESSOR_ROLE(), address(deployed.exitProcessor));
        deployed.qRail.grantRole(deployed.qRail.PROCESSOR_ROLE(), address(deployed.exitProcessor));
        deployed.qRail.grantRole(deployed.qRail.PROCESSOR_ROLE(), address(deployed.withdrawer));
        deployed.strategy.grantRole(deployed.strategy.PROCESSOR_MANAGER_ROLE(), config.admin);
        deployed.qRail.grantRole(deployed.qRail.PROCESSOR_MANAGER_ROLE(), config.admin);
        _setProcessorRules(config, deployed);
        deployed.manager.grantRole(deployed.manager.KEEPER_ROLE(), address(deployed.resolver));
        deployed.bagFactory.grantRole(deployed.bagFactory.CREATOR_ROLE(), address(deployed.withdrawalRequest));
        deployed.withdrawalRequest.setWithdrawer(address(deployed.withdrawer));
        deployed.withdrawalRequest.grantRole(deployed.withdrawalRequest.RESOLVER_ROLE(), address(deployed.resolver));
        deployed.resolver.grantRole(deployed.resolver.KEEPER_ROLE(), config.admin);
    }

    function _setProcessorRules(Config memory config, Deployed memory deployed) private {
        IVault.FunctionRule memory rule = _emptyRule();
        deployed.strategy.setProcessorRule(config.rail, IERC20.transfer.selector, rule);
        deployed.strategy.setProcessorRule(
            address(deployed.manager), RailStakePositionManager.createPosition.selector, rule
        );
        deployed.strategy.setProcessorRule(
            address(deployed.strategy), StakedRailStrategy.processorBurnShares.selector, rule
        );
        deployed.qRail.setProcessorRule(address(deployed.qRail), QueuedRailStrategy.processorMintShares.selector, rule);
        deployed.qRail.setProcessorRule(address(deployed.qRail), QueuedRailStrategy.processorBurnShares.selector, rule);
    }

    function _emptyRule() private pure returns (IVault.FunctionRule memory rule) {
        rule.isActive = true;
        rule.paramRules = new IVault.ParamRule[](0);
        rule.validator = IValidator(address(0));
    }

    error AdminMustBeBroadcasterForInitialSetup();
}
