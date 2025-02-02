// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";

uint16 constant TREE_SIZE = type(uint16).max;
uint16 constant TREE_SIZE_LOG2 = 16 - 1; // floor(log2(type(uint16).max))

/// @notice Returns the least significant bit (LSB) of a given unsigned 8-bit integer.
/// @param x The unsigned 8-bit integer.
/// @return The least significant bit of x.
function lsb(uint16 x) pure returns (uint16) {
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
        /// Fixed-size array of size `type(uint16).max`. Stores `type(uint16).max - 1` keys.
        /// Using 1-indexed arrays for convenience working with `lsb`.
        /// We reserve index `0` to store the total cumulative quantity. Hence, `0` is not a valid key.
        mapping(uint16 => euint128) tree;
        /// Keeps track of the largest insertedValue. This one is encrypted
        euint16 largestIndex;
    }

    function init(Storage storage _this) internal {
        _this.largestIndex = TFHE.asEuint16(0);
        TFHE.allowThis(_this.largestIndex);
        _this.tree[0] = TFHE.asEuint128(0);
        TFHE.allowThis(_this.tree[0]);
    }

    /// @notice Increments the cumulative quantity stored at a given index.
    /// @dev Preserves properties of the Fenwick tree. For increased privacy, consider multiple `0` quantity updates at
    /// random keys.
    function update(Storage storage _this, uint16 atKey, euint128 quantity) internal {
        if (atKey == 0) revert FT_InvalidPriceRange();

        _this.largestIndex = TFHE.select(
            TFHE.eq(quantity, 0),
            _this.largestIndex,
            TFHE.select(TFHE.gt(atKey, _this.largestIndex), TFHE.asEuint16(atKey), _this.largestIndex)
        );
        TFHE.allowThis(_this.largestIndex);

        uint16 index = atKey;

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

    /// @notice Queries the cumulative quantity at a given index.
    function query(Storage storage _this, uint16 atKey) internal returns (euint128) {
        if (atKey == 0) revert FT_InvalidPriceRange();

        euint128 sum = TFHE.asEuint128(0);
        uint16 idx = atKey;

        // We're guaranteed that decrementing by lsb will eventually reach 0.
        while (idx != 0) {
            sum = TFHE.add(sum, _this.tree[idx]);
            unchecked {
                idx -= lsb(idx);
            }
        }

        TFHE.allowThis(sum);
        return sum;
    }

    /// @dev Searching a key requires logic that depends of the result of subsequent decryptions. As decryption is an
    /// asynchronous process in the fhEVM, we store the state of this computation here. Decryption responsibility is
    /// left to the calling contract.
    struct SearchKeyIterator {
        euint128 rank;
        euint16 fallbackIdx;
        /// When unset, means the search is not running.
        euint16 idx;
        /// When set, marks the end of the search.
        euint16 foundIdx;
    }

    /// @notice Initializes the search key iterator, answering the query "what is the first index at which the
    /// cumulative quantity is equal or higher than targetQuantity?". If that index does not exists, the search will
    /// resolve to the largest index.
    /// @dev In the context of the single-price auction, we will need to fallback to the latest index to make sure
    /// that auctions that did not fulfilled the entirety of the distributed tokens will still point to the clearing
    /// price. This behavior can be changed if needed, for instance setting `fallbackIdx` to `TFHE.asEuint16(0)` can be
    /// used to mark a "not found" index.
    function startSearchKey(Storage storage _this, uint128 targetQuantity) internal returns (SearchKeyIterator memory) {
        SearchKeyIterator memory it;
        it.rank = TFHE.asEuint128(targetQuantity);
        TFHE.allowThis(it.rank);
        it.fallbackIdx = _this.largestIndex;
        it.idx = TFHE.asEuint16(0);
        TFHE.allowThis(it.idx);
        it.foundIdx = euint16.wrap(0);

        return it;
    }

    function stepSearchKey(Storage storage _this, SearchKeyIterator storage it, uint16 idx) internal {
        // If already at the end of the search, stop
        if (TFHE.isInitialized(it.foundIdx)) {
            return;
        }

        // If the search just starts, initialize with the root index.
        if (idx == 0) {
            idx = uint16(1 << TREE_SIZE_LOG2);
        }

        ebool isRankLteTreeIdx = TFHE.le(it.rank, _this.tree[idx]);
        if (lsb(idx) == 1) {
            it.foundIdx = TFHE.select(isRankLteTreeIdx, TFHE.asEuint16(idx), it.fallbackIdx);
            TFHE.allowThis(it.foundIdx);
            it.idx = euint16.wrap(0);

            return;
        }

        euint16 lsbDiv2 = TFHE.asEuint16(lsb(idx) >> 1);

        it.fallbackIdx = TFHE.select(isRankLteTreeIdx, TFHE.asEuint16(idx), it.fallbackIdx);
        TFHE.allowThis(it.fallbackIdx);
        it.rank = TFHE.select(isRankLteTreeIdx, it.rank, TFHE.sub(it.rank, _this.tree[idx]));
        TFHE.allowThis(it.rank);
        it.idx = TFHE.select(isRankLteTreeIdx, TFHE.sub(idx, lsbDiv2), TFHE.add(idx, lsbDiv2));
        TFHE.allowThis(it.idx);
    }

    /// @dev Returns the encrypted sum of all inserted values. Decryption is left to the caller.
    function totalValue(Storage storage _tree) internal view returns (euint128) {
        return _tree.tree[0];
    }
}
