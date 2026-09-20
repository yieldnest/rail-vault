// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library ActiveStakeList {
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

    // The caller supplies fresh, unique IDs from the staking contract.
    function add(List storage self, uint256 stakeId) internal {
        if (stakeId == NO_STAKE_ID) revert InvalidStakeId();
        if (self.count == 0) {
            self.first = stakeId;
        } else {
            self.next[self.last] = stakeId;
        }
        self.next[stakeId] = NO_STAKE_ID;
        self.last = stakeId;
        self.count++;
    }

    // Head removal is O(1); arbitrary removal walks to the predecessor.
    function remove(List storage self, uint256 stakeId) internal {
        uint256 previous = NO_STAKE_ID;
        uint256 current = head(self);
        while (current != stakeId) {
            if (current == NO_STAKE_ID) revert UnknownStakeId();
            previous = current;
            current = self.next[current];
        }
        if (current == NO_STAKE_ID) revert UnknownStakeId();

        if (previous == NO_STAKE_ID) {
            self.first = self.next[stakeId];
        } else {
            self.next[previous] = self.next[stakeId];
        }
        if (stakeId == self.last) self.last = previous;
        delete self.next[stakeId];
        self.count--;
    }

    function toArray(List storage self) internal view returns (uint256[] memory ids) {
        ids = new uint256[](self.count);
        uint256 stakeId = head(self);
        for (uint256 i = 0; i < self.count; i++) {
            ids[i] = stakeId;
            stakeId = self.next[stakeId];
        }
    }
}
