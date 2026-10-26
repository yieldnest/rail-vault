// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IVault} from "@yieldnest-vault/interface/IVault.sol";
import {IValidator} from "@yieldnest-vault/interface/IValidator.sol";
import {BeaconProxyFactory} from "@yieldnest-vault-withdrawals/BeaconProxyFactory.sol";
import {WithdrawalRequest} from "@yieldnest-vault-withdrawals/WithdrawalRequest.sol";

import {QueuedRailStrategy} from "../src/core/QueuedRailStrategy.sol";
import {StakedRailStrategy} from "../src/core/StakedRailStrategy.sol";
import {RailRewardsProcessor} from "../src/processors/RailRewardsProcessor.sol";
import {StakedRailProcessor} from "../src/processors/StakedRailProcessor.sol";
import {QueuedRailProcessor} from "../src/processors/QueuedRailProcessor.sol";
import {RailStakePositionManager} from "../src/core/RailStakePositionManager.sol";
import {BaseWithdrawer} from "@yieldnest-vault-withdrawals/withdrawers/BaseWithdrawer.sol";
import {SingleAssetFIFOResolver} from "../src/withdrawals/SingleAssetFIFOResolver.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    QueuedRailDeploymentLib,
    QueuedRailSetupLib,
    StakedRailDeploymentLib,
    StakedRailSetupLib,
    RailManagerDeploymentLib,
    RailProcessorsDeploymentLib,
    WithdrawalRequestDeploymentLib,
    WithdrawalSupportDeploymentLib
} from "./libraries/RailDeploymentLib.sol";

contract RailStrategyDeployer {
    struct Config {
        address admin;
        address rail;
        address staking;
        address splitsSwapper;
        uint256 stakeChunkSize;
        bool unpause;
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

    Config private configuration;
    address public immutable operator;
    bool public deployed;

    error InvalidAdmin();
    error OnlyOperator();
    error AlreadyDeployed();

    event StrategyDeployed(address indexed strategy, address indexed qRail, address indexed manager);

    constructor(Config memory config_) {
        if (config_.admin == address(0)) revert InvalidAdmin();
        configuration = config_;
        operator = msg.sender;
    }

    function deploy() external returns (Deployed memory result) {
        if (msg.sender != operator) revert OnlyOperator();
        if (deployed) revert AlreadyDeployed();
        deployed = true;
        Config memory settings = configuration;
        result = _deploy(settings);
        _wire(settings, result);
        emit StrategyDeployed(address(result.strategy), address(result.qRail), address(result.manager));
    }

    function _deploy(Config memory settings) private returns (Deployed memory result) {
        result.manager = RailManagerDeploymentLib.deploy(settings.rail, settings.staking, settings.admin);
        result.qRail = QueuedRailStrategy(
            payable(address(
                    new TransparentUpgradeableProxy(
                        QueuedRailDeploymentLib.deployImplementation(),
                        settings.admin,
                        abi.encodeCall(
                            QueuedRailStrategy.initialize,
                            (
                                address(this),
                                "Queued RAIL",
                                "qRAIL",
                                IERC20Metadata(settings.rail).decimals(),
                                false,
                                false,
                                true,
                                0
                            )
                        )
                    )
                ))
        );
        QueuedRailSetupLib.configure(result.qRail, settings.rail, address(result.manager.unlockedRail()));
        result.strategy = StakedRailStrategy(
            payable(address(
                    new TransparentUpgradeableProxy(
                        StakedRailDeploymentLib.deployImplementation(),
                        settings.admin,
                        abi.encodeCall(
                            StakedRailStrategy.initialize,
                            (
                                address(this),
                                "Staked RAIL",
                                "stRAIL",
                                IERC20Metadata(settings.rail).decimals(),
                                true,
                                false,
                                true,
                                0,
                                result.manager,
                                result.qRail
                            )
                        )
                    )
                ))
        );
        StakedRailSetupLib.configure(result.strategy, settings.rail);
        result.bagFactory = WithdrawalSupportDeploymentLib.deployBagFactory(settings.admin);
        result.withdrawalRequest =
            WithdrawalRequestDeploymentLib.deploy(settings.admin, address(result.qRail), address(result.bagFactory));
        result.withdrawer = WithdrawalSupportDeploymentLib.deployWithdrawer(
            settings.admin, address(result.qRail), address(result.withdrawalRequest)
        );
        result.resolver =
            RailProcessorsDeploymentLib.deployResolver(result.qRail, result.withdrawalRequest, settings.admin);
        result.processor =
            RailProcessorsDeploymentLib.deployStakedProcessor(settings.admin, result.strategy, settings.stakeChunkSize);
        result.queuedRailProcessor = RailProcessorsDeploymentLib.deployQueuedProcessor(result.qRail, result.manager);
        result.rewardsProcessor =
            RailProcessorsDeploymentLib.deployRewardsProcessor(result.manager, settings.splitsSwapper);
    }

    function _wire(Config memory settings, Deployed memory result) private {
        result.strategy.grantRole(result.strategy.FEE_MANAGER_ROLE(), settings.admin);
        result.manager.grantRole(result.manager.PAUSER_ROLE(), settings.admin);
        result.manager.grantRole(result.manager.CREATOR_ROLE(), address(result.strategy));
        result.manager.grantRole(result.manager.QUEUER_ROLE(), address(result.strategy));
        result.manager.grantRole(result.manager.CLAIMER_ROLE(), address(result.qRail));
        result.manager.grantRole(result.manager.TOKEN_WITHDRAWER_ROLE(), address(result.rewardsProcessor));
        result.strategy.grantRole(result.strategy.PROCESSOR_ROLE(), address(result.processor));
        result.qRail.grantRole(result.qRail.PROCESSOR_ROLE(), address(result.queuedRailProcessor));
        result.strategy.grantRole(result.strategy.PROCESSOR_MANAGER_ROLE(), address(this));
        result.qRail.grantRole(result.qRail.PROCESSOR_MANAGER_ROLE(), address(this));
        _setProcessorRules(settings, result);
        result.strategy.revokeRole(result.strategy.PROCESSOR_MANAGER_ROLE(), address(this));
        result.qRail.revokeRole(result.qRail.PROCESSOR_MANAGER_ROLE(), address(this));
        result.strategy.grantRole(result.strategy.PROCESSOR_MANAGER_ROLE(), settings.admin);
        result.qRail.grantRole(result.qRail.PROCESSOR_MANAGER_ROLE(), settings.admin);

        result.bagFactory.grantRole(result.bagFactory.CREATOR_ROLE(), address(result.withdrawalRequest));
        result.bagFactory.revokeRole(result.bagFactory.CREATOR_ROLE(), address(this));
        result.withdrawalRequest.setWithdrawer(address(result.withdrawer));
        result.withdrawalRequest.grantRole(result.withdrawalRequest.RESOLVER_ROLE(), address(result.resolver));
        result.withdrawalRequest.revokeRole(result.withdrawalRequest.RESOLVER_ROLE(), address(this));
        result.withdrawalRequest.grantRole(result.withdrawalRequest.CONFIGURATION_MANAGER_ROLE(), settings.admin);
        result.withdrawalRequest.revokeRole(result.withdrawalRequest.CONFIGURATION_MANAGER_ROLE(), address(this));
        result.qRail.grantRole(result.qRail.ALLOCATOR_ROLE(), address(result.strategy));
        result.qRail.grantRole(result.qRail.ALLOCATOR_ROLE(), address(result.withdrawer));

        if (settings.unpause) {
            result.strategy.grantRole(result.strategy.UNPAUSER_ROLE(), address(this));
            result.strategy.unpause();
            result.strategy.revokeRole(result.strategy.UNPAUSER_ROLE(), address(this));
        }
        result.strategy.grantRole(result.strategy.UNPAUSER_ROLE(), settings.admin);

        _handover(IAccessControl(address(result.manager)), settings.admin);
        _handover(IAccessControl(address(result.strategy)), settings.admin);
        _handover(IAccessControl(address(result.qRail)), settings.admin);
        _handover(IAccessControl(address(result.bagFactory)), settings.admin);
        _handover(IAccessControl(address(result.withdrawalRequest)), settings.admin);
    }

    function _handover(IAccessControl target, address admin) private {
        target.grantRole(bytes32(0), admin);
        target.renounceRole(bytes32(0), address(this));
    }

    function _setProcessorRules(Config memory config, Deployed memory result) private {
        IVault.FunctionRule memory rule = _emptyRule();
        rule.paramRules = new IVault.ParamRule[](2);
        rule.paramRules[0].paramType = IVault.ParamType.ADDRESS;
        rule.paramRules[0].allowList = new address[](1);
        rule.paramRules[0].allowList[0] = address(result.manager);
        rule.paramRules[1].paramType = IVault.ParamType.UINT256;
        result.strategy.setProcessorRule(config.rail, IERC20.approve.selector, rule);
        rule = _emptyRule();
        result.strategy
            .setProcessorRule(address(result.manager), RailStakePositionManager.createPosition.selector, rule);
        result.strategy.setProcessorRule(address(result.strategy), StakedRailStrategy.queuePosition.selector, rule);

        rule.paramRules = new IVault.ParamRule[](2);
        rule.paramRules[0].paramType = IVault.ParamType.UINT256;
        rule.paramRules[1].paramType = IVault.ParamType.ADDRESS;
        rule.paramRules[1].allowList = new address[](1);
        rule.paramRules[1].allowList[0] = address(result.qRail);
        result.qRail.setProcessorRule(address(result.manager), RailStakePositionManager.claimPosition.selector, rule);
        rule.paramRules[0].isArray = true;
        result.qRail
            .setProcessorRule(address(result.manager), RailStakePositionManager.claimMaturedPositions.selector, rule);
    }

    function _emptyRule() private pure returns (IVault.FunctionRule memory rule) {
        rule.isActive = true;
        rule.paramRules = new IVault.ParamRule[](0);
        rule.validator = IValidator(address(0));
    }
}
