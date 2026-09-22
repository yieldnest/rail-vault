// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Bag} from "@yieldnest-vault-withdrawals/Bag.sol";
import {BeaconProxyFactory} from "@yieldnest-vault-withdrawals/BeaconProxyFactory.sol";
import {WithdrawalRequest} from "@yieldnest-vault-withdrawals/WithdrawalRequest.sol";
import {MinAmountRequestPolicy} from "@yieldnest-vault-withdrawals/policies/MinAmountRequestPolicy.sol";
import {BaseWithdrawer} from "@yieldnest-vault-withdrawals/withdrawers/BaseWithdrawer.sol";
import {QueuedRailStrategy} from "../../src/core/QueuedRailStrategy.sol";
import {StakedRailStrategy} from "../../src/core/StakedRailStrategy.sol";
import {RailStakePositionManager} from "../../src/core/RailStakePositionManager.sol";
import {IRailgunStaking} from "../../src/railgun/IRailgunStaking.sol";
import {IRailgunGovernorRewards} from "../../src/railgun/IRailgunGovernorRewards.sol";
import {StakedRailProcessor} from "../../src/processors/StakedRailProcessor.sol";
import {QueuedRailProcessor} from "../../src/processors/QueuedRailProcessor.sol";
import {RailRewardsProcessor} from "../../src/processors/RailRewardsProcessor.sol";
import {SingleAssetFIFOResolver} from "../../src/withdrawals/SingleAssetFIFOResolver.sol";

// External library calls keep creation bytecode out of the deployer's runtime.
// They execute in the deployer's context, which holds temporary setup roles.
library QueuedRailDeploymentLib {
    function deployImplementation() external returns (address) {
        return address(new QueuedRailStrategy());
    }
}

library StakedRailDeploymentLib {
    function deployImplementation() external returns (address) {
        return address(new StakedRailStrategy());
    }
}

library RailManagerDeploymentLib {
    function deploy(address rail, address staking) external returns (RailStakePositionManager) {
        return new RailStakePositionManager(address(this), IERC20(rail), IRailgunStaking(staking));
    }
}

library WithdrawalSupportDeploymentLib {
    function deployBagFactory(address admin) external returns (BeaconProxyFactory) {
        Bag bag = new Bag();
        BeaconProxyFactory implementation = new BeaconProxyFactory();
        return BeaconProxyFactory(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    admin,
                    abi.encodeCall(BeaconProxyFactory.initialize, (address(bag), address(this), address(this), admin))
                )
            )
        );
    }

    function deployWithdrawer(address admin, address qRail, address requests) external returns (BaseWithdrawer) {
        BaseWithdrawer implementation = new BaseWithdrawer();
        return BaseWithdrawer(
            payable(address(
                    new TransparentUpgradeableProxy(
                        address(implementation), admin, abi.encodeCall(BaseWithdrawer.initialize, (qRail, requests))
                    )
                ))
        );
    }
}

library WithdrawalRequestDeploymentLib {
    function deploy(address admin, address qRail, address bagFactory) external returns (WithdrawalRequest) {
        WithdrawalRequest implementation = new WithdrawalRequest();
        MinAmountRequestPolicy policy = new MinAmountRequestPolicy(1);
        return WithdrawalRequest(
            payable(address(
                    new TransparentUpgradeableProxy(
                        address(implementation),
                        admin,
                        abi.encodeCall(
                            WithdrawalRequest.initialize,
                            (
                                qRail,
                                address(this),
                                address(this),
                                address(this),
                                admin,
                                bagFactory,
                                address(this),
                                address(policy),
                                uint256(1024)
                            )
                        )
                    )
                ))
        );
    }
}

library RailProcessorsDeploymentLib {
    function deployResolver(QueuedRailStrategy qRail, WithdrawalRequest requests)
        external
        returns (SingleAssetFIFOResolver)
    {
        return new SingleAssetFIFOResolver(IERC4626(address(qRail)), requests);
    }

    function deployStakedProcessor(address admin, StakedRailStrategy strategy, uint256 chunkSize)
        external
        returns (StakedRailProcessor)
    {
        return new StakedRailProcessor(admin, strategy, chunkSize);
    }

    function deployQueuedProcessor(QueuedRailStrategy qRail, RailStakePositionManager manager)
        external
        returns (QueuedRailProcessor)
    {
        return new QueuedRailProcessor(address(this), qRail, manager);
    }

    function deployRewardsProcessor(
        address admin,
        address rewards,
        RailStakePositionManager manager,
        IERC20[] memory tokens,
        uint256 interval
    ) external returns (RailRewardsProcessor) {
        return new RailRewardsProcessor(admin, IRailgunGovernorRewards(rewards), manager, tokens, interval);
    }
}
