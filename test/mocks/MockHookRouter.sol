// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@yieldnest-vault/interface/IHooks.sol";
import {IVault} from "@yieldnest-vault/interface/IVault.sol";

/// @dev Models MetaHooks' ordinary calls to a child hook, preserving the router as msg.sender.
contract MockHookRouter {
    IVault public immutable VAULT;
    IHooks public immutable child;

    constructor(IVault vault_, IHooks child_) {
        VAULT = vault_;
        child = child_;
    }

    function getConfig() external view returns (IHooks.Config memory) {
        return child.getConfig();
    }

    fallback() external {
        require(msg.sender == address(VAULT), "only vault");
        (bool success, bytes memory result) = address(child).call(msg.data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }
}
