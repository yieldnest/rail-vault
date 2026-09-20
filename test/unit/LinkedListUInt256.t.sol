// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LinkedListUInt256} from "../../src/lib/LinkedListUInt256.sol";

contract LinkedListUInt256Test is Test {
    using LinkedListUInt256 for LinkedListUInt256.List;

    LinkedListUInt256.List internal list;

    function testEmptyList() external view {
        assertEq(list.head(), LinkedListUInt256.NO_STAKE_ID);
        assertEq(list.tail(), LinkedListUInt256.NO_STAKE_ID);
        assertEq(list.toArray().length, 0);
    }

    function testAddRemoveAndRefill() external {
        list.add(0);
        list.add(1);
        list.add(2);
        list.remove(1);
        assertEq(list.next[0], 2);
        assertEq(list.next[1], 0);
        assertEq(list.count, 2);
        assertEq(list.toArray()[0], 0);
        assertEq(list.toArray()[1], 2);
        list.remove(2);
        assertEq(list.tail(), 0);
        assertEq(list.next[0], LinkedListUInt256.NO_STAKE_ID);
        list.remove(0);
        assertEq(list.head(), LinkedListUInt256.NO_STAKE_ID);
        assertEq(list.tail(), LinkedListUInt256.NO_STAKE_ID);
        assertEq(list.count, 0);
        list.add(3);
        assertEq(list.head(), 3);
        assertEq(list.tail(), 3);
        assertEq(list.next[3], LinkedListUInt256.NO_STAKE_ID);
        assertEq(list.count, 1);
    }

    function testRemoveMissingStake() external {
        list.add(0);
        vm.expectRevert(LinkedListUInt256.UnknownStakeId.selector);
        this.remove(1);
        assertEq(list.head(), 0);
        assertEq(list.count, 1);
    }

    function testRemoveFromEmptyList() external {
        vm.expectRevert(LinkedListUInt256.UnknownStakeId.selector);
        this.remove(0);
    }

    function testRemoveSentinel() external {
        vm.expectRevert(LinkedListUInt256.UnknownStakeId.selector);
        this.remove(LinkedListUInt256.NO_STAKE_ID);
    }

    function testAddSentinel() external {
        vm.expectRevert(LinkedListUInt256.InvalidStakeId.selector);
        this.add(LinkedListUInt256.NO_STAKE_ID);
    }

    function add(uint256 stakeId) external {
        list.add(stakeId);
    }

    function remove(uint256 stakeId) external {
        list.remove(stakeId);
    }
}
