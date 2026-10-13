// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IFactory} from "@yieldnest-vault-withdrawals/interface/IFactory.sol";

/// @notice Creates an independently upgradeable TUP for each withdrawal bag.
/// @dev Changing the template affects future bags only. Existing bags are upgraded
/// through their own ProxyAdmin by the configured governance owner.
contract TransparentBagFactory is AccessControlUpgradeable, IFactory {
    bytes32 public constant CREATOR_ROLE = keccak256("CREATOR_ROLE");
    bytes32 public constant IMPLEMENTATION_MANAGER_ROLE = keccak256("IMPLEMENTATION_MANAGER_ROLE");

    address public implementation;
    address public proxyAdminOwner;
    uint256[50] private __gap;

    error InvalidConfiguration();
    event ProxyCreated(address indexed creator, address indexed proxy, address indexed implementation);
    event ImplementationUpgraded(address indexed previousImplementation, address indexed newImplementation);

    constructor() {
        _disableInitializers();
    }

    function initialize(address implementation_, address admin, address creator, address proxyAdminOwner_)
        external
        initializer
    {
        if (
            implementation_.code.length == 0 || admin == address(0) || creator == address(0)
                || proxyAdminOwner_ == address(0)
        ) revert InvalidConfiguration();
        __AccessControl_init();
        implementation = implementation_;
        proxyAdminOwner = proxyAdminOwner_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CREATOR_ROLE, creator);
        _grantRole(IMPLEMENTATION_MANAGER_ROLE, proxyAdminOwner_);
    }

    function create(bytes calldata initData) external onlyRole(CREATOR_ROLE) returns (address proxy) {
        proxy = address(new TransparentUpgradeableProxy(implementation, proxyAdminOwner, initData));
        emit ProxyCreated(msg.sender, proxy, implementation);
    }

    /// @notice Sets the implementation for future bags; does not upgrade existing bags.
    function upgradeImplementation(address newImplementation) external onlyRole(IMPLEMENTATION_MANAGER_ROLE) {
        if (newImplementation.code.length == 0) revert InvalidConfiguration();
        emit ImplementationUpgraded(implementation, newImplementation);
        implementation = newImplementation;
    }
}
