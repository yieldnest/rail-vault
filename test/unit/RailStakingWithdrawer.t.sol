// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {RAILxVault} from "../../src/RAILxVault.sol";
import {RailProvider} from "../../src/RailProvider.sol";
import {RailStakingWithdrawer} from "../../src/RailStakingWithdrawer.sol";
import {QueuedRailToken} from "../../src/tokens/QueuedRailToken.sol";
import {RailWithdrawalNFT} from "../../src/withdrawals/RailWithdrawalNFT.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRailStaking} from "../mocks/MockRailStaking.sol";

contract RailStakingWithdrawerTest is Test {
    address user = makeAddr("user");

    MockERC20 rail;
    MockRailStaking staking;
    RailProvider provider;
    QueuedRailToken queuedRail;
    RailStakingWithdrawer withdrawer;
    RailWithdrawalNFT withdrawalNFT;
    RAILxVault vault;

    function setUp() external {
        rail = new MockERC20("RAIL", "RAIL", 18);
        staking = new MockRailStaking(rail);
        provider = new RailProvider(address(rail));
        queuedRail = new QueuedRailToken(address(this));

        RailStakingWithdrawer withdrawerImplementation = new RailStakingWithdrawer();
        withdrawer = RailStakingWithdrawer(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(withdrawerImplementation),
                        makeAddr("withdrawerProxyAdmin"),
                        abi.encodeCall(RailStakingWithdrawer.initialize, (address(this), address(rail), staking, queuedRail))
                    )
                )
            )
        );

        withdrawalNFT = new RailWithdrawalNFT(address(this), queuedRail, withdrawer);

        RAILxVault vaultImplementation = new RAILxVault();
        vault = RAILxVault(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(vaultImplementation),
                        makeAddr("vaultProxyAdmin"),
                        abi.encodeCall(RAILxVault.initialize, (address(this), address(rail), address(provider), withdrawalNFT))
                    )
                )
            )
        );
        queuedRail.grantRole(queuedRail.MINTER_ROLE(), address(withdrawer));
        queuedRail.grantRole(queuedRail.BURNER_ROLE(), address(withdrawer));
        withdrawalNFT.grantRole(withdrawalNFT.MINTER_ROLE(), address(vault));
        withdrawer.grantRole(withdrawer.PROCESSOR_ROLE(), address(this));
        withdrawer.grantRole(withdrawer.UNPAUSER_ROLE(), address(this));
        vault.grantRole(vault.BUFFER_MANAGER_ROLE(), address(this));
        vault.grantRole(vault.UNPAUSER_ROLE(), address(this));

        vault.setBuffer(address(withdrawer));
        withdrawer.unpause();
        vault.unpause();
    }

    function testAccountingModelsLiquidQueuedAndStakedRail() external {
        rail.mint(address(withdrawer), 100 ether);

        withdrawer.stakeIdle(60 ether);
        withdrawer.processAccounting();
        assertEq(withdrawer.stakedRailBalance(), 60 ether);
        assertEq(withdrawer.queuedRailBalance(), 0);
        assertEq(withdrawer.totalBaseAssets(), 100 ether);

        withdrawer.unlockStake(0, address(this));
        withdrawer.processAccounting();
        assertEq(withdrawer.stakedRailBalance(), 0);
        assertEq(withdrawer.queuedRailBalance(), 60 ether);
        assertEq(withdrawer.asyncWithdrawalBalance(address(rail)), 60 ether);
        assertEq(withdrawer.totalBaseAssets(), 100 ether);
        assertEq(withdrawer.totalAssets(), 100 ether);
        assertEq(queuedRail.balanceOf(address(this)), 60 ether);
    }

    function testVaultBurnsSharesIntoNftAndNftClaimsQueuedRail() external {
        rail.mint(user, 100 ether);
        vm.startPrank(user);
        rail.approve(address(vault), 100 ether);
        vault.deposit(100 ether, user);
        (uint256 tokenId, uint256 assets) = vault.requestWithdrawal(40 ether, user, user);
        vm.stopPrank();

        assertEq(vault.balanceOf(user), 60 ether);
        assertEq(withdrawalNFT.ownerOf(tokenId), user);
        assertEq(assets, 40 ether);

        rail.mint(address(withdrawer), 40 ether);
        withdrawer.stakeIdle(40 ether);
        withdrawer.unlockStake(0, address(this));
        queuedRail.approve(address(withdrawalNFT), 40 ether);
        withdrawalNFT.bagQueuedRail(tokenId, 40 ether);

        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(user);
        withdrawalNFT.claim(tokenId, user);

        assertEq(rail.balanceOf(user), 40 ether);
        assertEq(queuedRail.balanceOf(address(withdrawalNFT)), 0);
    }
}
