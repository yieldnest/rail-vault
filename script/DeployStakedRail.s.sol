// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IVault} from "@yieldnest-vault/interface/IVault.sol";
import {IValidator} from "@yieldnest-vault/interface/IValidator.sol";
import {Bag} from "@yieldnest-vault-withdrawals/Bag.sol";
import {BeaconProxyFactory} from "@yieldnest-vault-withdrawals/BeaconProxyFactory.sol";
import {WithdrawalRequest} from "@yieldnest-vault-withdrawals/WithdrawalRequest.sol";
import {MinAmountRequestPolicy} from "@yieldnest-vault-withdrawals/policies/MinAmountRequestPolicy.sol";

import {QueuedRailStrategy} from "../src/core/QueuedRailStrategy.sol";
import {StakedRailStrategy} from "../src/core/StakedRailStrategy.sol";
import {RailRewardsProcessor} from "../src/processors/RailRewardsProcessor.sol";
import {StakedRailProcessor} from "../src/processors/StakedRailProcessor.sol";
import {QueuedRailProcessor} from "../src/processors/QueuedRailProcessor.sol";
import {IRailgunGovernorRewards} from "../src/railgun/IRailgunGovernorRewards.sol";
import {IRailgunStaking} from "../src/railgun/IRailgunStaking.sol";
import {RailStakePositionManager} from "../src/core/RailStakePositionManager.sol";
import {BaseWithdrawer} from "@yieldnest-vault-withdrawals/withdrawers/BaseWithdrawer.sol";
import {SingleAssetFIFOResolver} from "../src/withdrawals/SingleAssetFIFOResolver.sol";

contract DeployStakedRail is Script {
    struct Config {
        address admin;
        address rail;
        address staking;
        address governorRewards;
        address[] rewardTokens;
        uint256 nextRewardClaimInterval;
        uint256 stakeChunkSize;
    }

    struct Deployed {
        QueuedRailStrategy qRail;
        RailStakePositionManager manager;
        StakedRailStrategy strategy;
        BeaconProxyFactory bagFactory;
        WithdrawalRequest withdrawalRequest;
        BaseWithdrawer withdrawer;
        SingleAssetFIFOResolver resolver;
        StakedRailProcessor processor;
        QueuedRailProcessor queuedRailProcessor;
        RailRewardsProcessor rewardsProcessor;
    }

    function run() external {
        Config memory config = Config({
            admin: vm.envOr("ADMIN", msg.sender),
            rail: vm.envAddress("RAIL"),
            staking: vm.envAddress("RAIL_STAKING"),
            governorRewards: vm.envAddress("GOVERNOR_REWARDS"),
            rewardTokens: vm.envAddress("REWARD_TOKENS", ","),
            nextRewardClaimInterval: vm.envUint("NEXT_REWARD_CLAIM_INTERVAL"),
            stakeChunkSize: vm.envOr("STAKE_CHUNK_SIZE", uint256(1000 ether))
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
        vm.serializeAddress(json, "processor", address(deployed.processor));
        vm.serializeAddress(json, "queuedRailProcessor", address(deployed.queuedRailProcessor));
        vm.serializeAddress(json, "rewardsProcessor", address(deployed.rewardsProcessor));
        string memory output = vm.serializeAddress(json, "strategy", address(deployed.strategy));
        vm.writeJson(output, string.concat("deployments/staked-rail-", vm.toString(block.chainid), ".json"));
    }

    function _deploy(Config memory config) private returns (Deployed memory deployed) {
        deployed.manager =
            new RailStakePositionManager(config.admin, IERC20(config.rail), IRailgunStaking(config.staking));

        QueuedRailStrategy qRailImplementation = new QueuedRailStrategy();
        StakedRailStrategy strategyImplementation = new StakedRailStrategy();
        // The next two broadcaster deployments are qRAIL and stRAIL, both initialized at creation.
        address stakedRailAddress = vm.computeCreateAddress(config.admin, vm.getNonce(config.admin) + 1);
        deployed.qRail = QueuedRailStrategy(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(qRailImplementation),
                        config.admin,
                        abi.encodeCall(
                            QueuedRailStrategy.initialize,
                            (config.admin, config.rail, deployed.manager, stakedRailAddress)
                        )
                    )
                )
            )
        );

        deployed.strategy = StakedRailStrategy(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(strategyImplementation),
                        config.admin,
                        abi.encodeCall(
                            StakedRailStrategy.initialize,
                            (config.admin, config.rail, deployed.manager, deployed.qRail)
                        )
                    )
                )
            )
        );

        require(address(deployed.strategy) == stakedRailAddress, "Unexpected stRAIL address");

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

        BaseWithdrawer withdrawerImplementation = new BaseWithdrawer();
        deployed.withdrawer = BaseWithdrawer(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(withdrawerImplementation),
                        config.admin,
                        abi.encodeCall(
                            BaseWithdrawer.initialize,
                            (address(deployed.qRail), address(deployed.withdrawalRequest))
                        )
                    )
                )
            )
        );

        deployed.resolver =
            new SingleAssetFIFOResolver(
                IERC4626(address(deployed.qRail)),
                deployed.withdrawalRequest
            );

        deployed.processor = new StakedRailProcessor(
            config.admin,
            deployed.strategy,
            config.stakeChunkSize
        );
        deployed.queuedRailProcessor = new QueuedRailProcessor(config.admin, deployed.qRail);
        deployed.rewardsProcessor = new RailRewardsProcessor(
            config.admin,
            IRailgunGovernorRewards(config.governorRewards),
            deployed.manager,
            _toIERC20Array(config.rewardTokens),
            config.nextRewardClaimInterval
        );
    }

    function _wire(Config memory config, Deployed memory deployed) private {
        deployed.manager.grantRole(deployed.manager.PAUSER_ROLE(), config.admin);
        deployed.manager.grantRole(deployed.manager.CREATOR_ROLE(), address(deployed.strategy));
        deployed.strategy.grantRole(deployed.strategy.PROCESSOR_ROLE(), address(deployed.processor));
        deployed.strategy.grantRole(deployed.strategy.PROCESSOR_MANAGER_ROLE(), config.admin);
        deployed.qRail.grantRole(deployed.qRail.PROCESSOR_ROLE(), address(deployed.queuedRailProcessor));
        deployed.queuedRailProcessor.grantRole(deployed.queuedRailProcessor.KEEPER_ROLE(), config.admin);
        deployed.qRail.grantRole(deployed.qRail.PROCESSOR_MANAGER_ROLE(), config.admin);
        _setProcessorRules(config, deployed);
        deployed.manager.grantRole(deployed.manager.CLAIMER_ROLE(), address(deployed.qRail));
        deployed.manager.grantRole(deployed.manager.QUEUER_ROLE(), address(deployed.strategy));
        deployed.manager.grantRole(deployed.manager.KEEPER_ROLE(), address(deployed.rewardsProcessor));
        deployed.bagFactory.grantRole(deployed.bagFactory.CREATOR_ROLE(), address(deployed.withdrawalRequest));
        deployed.withdrawalRequest.setWithdrawer(address(deployed.withdrawer));
        deployed.withdrawalRequest.grantRole(deployed.withdrawalRequest.RESOLVER_ROLE(), address(deployed.resolver));
    }

    function _setProcessorRules(Config memory config, Deployed memory deployed) private {
        IVault.FunctionRule memory rule = _emptyRule();
        rule.paramRules = new IVault.ParamRule[](2);
        rule.paramRules[0].paramType = IVault.ParamType.ADDRESS;
        rule.paramRules[0].allowList = new address[](1);
        rule.paramRules[0].allowList[0] = address(deployed.manager);
        rule.paramRules[1].paramType = IVault.ParamType.UINT256;
        deployed.strategy.setProcessorRule(config.rail, IERC20.approve.selector, rule);
        rule = _emptyRule();
        deployed.strategy.setProcessorRule(
            address(deployed.manager), RailStakePositionManager.createPosition.selector, rule
        );
        deployed.strategy.setProcessorRule(address(deployed.strategy), StakedRailStrategy.queuePosition.selector, rule);

        rule.paramRules = new IVault.ParamRule[](2);
        rule.paramRules[0].paramType = IVault.ParamType.UINT256;
        rule.paramRules[1].paramType = IVault.ParamType.ADDRESS;
        rule.paramRules[1].allowList = new address[](1);
        rule.paramRules[1].allowList[0] = address(deployed.qRail);
        deployed.qRail.setProcessorRule(address(deployed.manager), RailStakePositionManager.claimPosition.selector, rule);
        rule.paramRules[0].isArray = true;
        deployed.qRail.setProcessorRule(address(deployed.manager), RailStakePositionManager.claimMaturedPositions.selector, rule);
    }

    function _emptyRule() private pure returns (IVault.FunctionRule memory rule) {
        rule.isActive = true;
        rule.paramRules = new IVault.ParamRule[](0);
        rule.validator = IValidator(address(0));
    }

    function _toIERC20Array(address[] memory tokens) private pure returns (IERC20[] memory erc20Tokens) {
        erc20Tokens = new IERC20[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            erc20Tokens[i] = IERC20(tokens[i]);
        }
    }

    error AdminMustBeBroadcasterForInitialSetup();
}
