// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ActiveStakeList} from "../../src/lib/ActiveStakeList.sol";

contract ActiveStakeListTest is Test {
    using ActiveStakeList for ActiveStakeList.List;

    ActiveStakeList.List internal list;

    function testEmptyList() external view {
        assertEq(list.head(), ActiveStakeList.NO_STAKE_ID);
        assertEq(list.tail(), ActiveStakeList.NO_STAKE_ID);
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
        assertEq(list.next[0], ActiveStakeList.NO_STAKE_ID);
        list.remove(0);
        assertEq(list.head(), ActiveStakeList.NO_STAKE_ID);
        assertEq(list.tail(), ActiveStakeList.NO_STAKE_ID);
        assertEq(list.count, 0);
        list.add(3);
        assertEq(list.head(), 3);
        assertEq(list.tail(), 3);
        assertEq(list.next[3], ActiveStakeList.NO_STAKE_ID);
        assertEq(list.count, 1);
    }

    function testRemoveMissingStake() external {
        list.add(0);
        vm.expectRevert(ActiveStakeList.UnknownStakeId.selector);
        this.remove(1);
        assertEq(list.head(), 0);
        assertEq(list.count, 1);
    }

    function testRemoveFromEmptyList() external {
        vm.expectRevert(ActiveStakeList.UnknownStakeId.selector);
        this.remove(0);
    }

    function testRemoveSentinel() external {
        vm.expectRevert(ActiveStakeList.UnknownStakeId.selector);
        this.remove(ActiveStakeList.NO_STAKE_ID);
    }

    function testAddSentinel() external {
        vm.expectRevert(ActiveStakeList.InvalidStakeId.selector);
        this.add(ActiveStakeList.NO_STAKE_ID);
    }

    function add(uint256 stakeId) external {
        list.add(stakeId);
    }

    function remove(uint256 stakeId) external {
        list.remove(stakeId);
    }
}
