// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";

uint8 constant TREE_SIZE = type(uint8).max;
uint8 constant TREE_SIZE_LOG2 = 7; // floor(log2(type(uint8).max))

/// @notice Returns the least significant bit (LSB) of a given unsigned 8-bit integer.
/// @param x The unsigned 8-bit integer.
/// @return The least significant bit of x.
function lsb(uint8 x) pure returns (uint8) {
    unchecked {
        return x & (~x + 1);
    }
}

/// @title HalfEncryptedFenwickTree
/// @author Loïc Payol <contact@loicpayol.fr>
/// @notice Implementation of a Fenwick Tree with encrypted values.
/// @dev This library allows for efficient range query and prefix sum calculations. Keys are never encrypted but their
/// value are. In order to make insertion at a given range private, users can insert multiple times zero values, making
/// sure an external observer can't be certain what key effectively contains meaningful value.
/// It does not support insertion of negative values. That would be useful to cancel user actions represented in this
/// data structure.
library HalfEncryptedFenwickTree {
    /// Thrown when requesting reserved key `0`.
    error FT_InvalidPriceRange();

    struct Storage {
        /// Fixed-size array of size `type(uint8).max`. Stores `type(uint8).max - 1` keys.
        /// Using 1-indexed arrays for convenience working with `lsb`.
        /// We reserve index `0` to store the total cumulative quantity. Hence, `0` is not a valid key.
        mapping(uint8 => euint128) tree;
        /// Keeps track of the largest insertedValue. This one is encrypted
        euint8 largestIndex;
    }

    function init(Storage storage _this) internal {
        _this.largestIndex = TFHE.asEuint8(0);
        TFHE.allowThis(_this.largestIndex);
    }

    /// @notice Update the value at a given index
    /// @dev Increments the cumulative quantity stored at the given index.
    /// Preserves properties of the Fenwick tree. For increased privacy, consider multiple `0` quantity updates at
    /// random keys.
    function update(Storage storage _this, uint8 atKey, euint128 quantity) internal {
        if (atKey == 0) revert FT_InvalidPriceRange();

        _this.largestIndex = TFHE.select(
            TFHE.eq(quantity, 0),
            _this.largestIndex,
            TFHE.select(TFHE.gt(atKey, _this.largestIndex), TFHE.asEuint8(atKey), _this.largestIndex)
        );
        TFHE.allowThis(_this.largestIndex);

        uint8 index = atKey;

        // 2) ... then detect it, as we're only moving forward.
        while (index >= atKey) {
            _this.tree[index] = TFHE.add(_this.tree[index], quantity);
            TFHE.allowThis(_this.tree[index]);

            // 1) Allow overflow...
            unchecked {
                index += lsb(index);
            }
        }

        _this.tree[0] = TFHE.add(_this.tree[0], quantity);
        TFHE.allowThis(_this.tree[0]);
    }

    /// @dev Searching a key requires logic that depends of the result of subsequent decryptions. As decryption is an
    /// asynchronous process in the fhEVM, we store the state of this computation here. Decryption responsibility is
    /// left to the calling contract.
    struct SearchKeyIterator {
        euint128 rank;
        euint8 fallbackIdx;
        /// When unset, means the search is not running.
        euint8 idx;
        /// When set, marks the end of the search.
        euint8 foundIdx;
    }

    function startSearchKey(Storage storage _this, uint128 targetQuantity) internal returns (SearchKeyIterator memory) {
        SearchKeyIterator memory it;
        it.rank = TFHE.asEuint128(targetQuantity);
        it.fallbackIdx = _this.largestIndex;
        it.idx = euint8.wrap(0);
        it.foundIdx = euint8.wrap(0);

        return it;
    }

    function stepSearchKey(Storage storage _this, SearchKeyIterator storage it, uint8 idx) internal {
        // If already at the end of the search, stop
        if (TFHE.isInitialized(it.foundIdx)) {
            return;
        }

        // If the search just starts, initialize with the root index.
        if (idx == 0) {
            idx = uint8(1 << TREE_SIZE_LOG2);
        }

        ebool isRankLteTreeIdx = TFHE.le(it.rank, _this.tree[idx]);
        if (lsb(idx) == 1) {
            it.foundIdx = TFHE.select(isRankLteTreeIdx, TFHE.asEuint8(idx), it.fallbackIdx);
            TFHE.allowThis(it.foundIdx);
            it.idx = euint8.wrap(0);

            return;
        }

        euint8 lsbDiv2 = TFHE.asEuint8(lsb(idx) >> 1);

        it.fallbackIdx = TFHE.select(isRankLteTreeIdx, TFHE.asEuint8(idx), it.fallbackIdx);
        TFHE.allowThis(it.fallbackIdx);
        it.rank = TFHE.select(isRankLteTreeIdx, it.rank, TFHE.sub(it.rank, _this.tree[idx]));
        TFHE.allowThis(it.rank);
        it.idx = TFHE.select(isRankLteTreeIdx, TFHE.sub(idx, lsbDiv2), TFHE.add(idx, lsbDiv2));
        TFHE.allowThis(it.idx);
    }
}
