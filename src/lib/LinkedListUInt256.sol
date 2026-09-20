// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library LinkedListUInt256 {
    uint256 internal constant NO_STAKE_ID = type(uint256).max;

    struct List {
        uint256 first;
        uint256 last;
        mapping(uint256 => uint256) next;
        uint256 count;
    }

    error UnknownStakeId();
    error InvalidStakeId();

    function head(List storage self) internal view returns (uint256) {
        return self.count == 0 ? NO_STAKE_ID : self.first;
    }

    function tail(List storage self) internal view returns (uint256) {
        return self.count == 0 ? NO_STAKE_ID : self.last;
    }

    // The caller supplies values that are not already in the list.
    function add(List storage self, uint256 value) internal {
        if (value == NO_STAKE_ID) revert InvalidStakeId();
        if (self.count == 0) {
            self.first = value;
        } else {
            self.next[self.last] = value;
        }
        self.next[value] = NO_STAKE_ID;
        self.last = value;
        self.count++;
    }

    // Head removal is O(1); arbitrary removal walks to the predecessor.
    function remove(List storage self, uint256 value) internal {
        uint256 previous = NO_STAKE_ID;
        uint256 current = head(self);
        while (current != value) {
            if (current == NO_STAKE_ID) revert UnknownStakeId();
            previous = current;
            current = self.next[current];
        }
        if (current == NO_STAKE_ID) revert UnknownStakeId();

        if (previous == NO_STAKE_ID) {
            self.first = self.next[value];
        } else {
            self.next[previous] = self.next[value];
        }
        if (value == self.last) self.last = previous;
        delete self.next[value];
        self.count--;
    }

    function toArray(List storage self) internal view returns (uint256[] memory values) {
        values = new uint256[](self.count);
        uint256 value = head(self);
        for (uint256 i = 0; i < self.count; i++) {
            values[i] = value;
            value = self.next[value];
        }
    }
}
