// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

contract TimeLockModifier {
    error LockActivated(bytes32 tag);
    mapping(bytes32 => uint256) public timeLocks;

    bytes32 internal constant TL_TAG_DEFAULT = bytes32(0x0);

    modifier checkLock() {
        _lockTag(bytes32(TL_TAG_DEFAULT));
        _;
    }

    modifier checkLockTag(bytes32 tag) {
        _lockTag(tag);
        _;
    }

    function _lockTag(bytes32 tag) private {
        if (timeLocks[tag] != 0) {
            if (block.timestamp <= timeLocks[tag]) {
                revert LockActivated(tag);
            }

            _clearLock(tag);
        }
    }

    function _startLockForDuration(uint256 duration) internal {
        _startLockForDuration(TL_TAG_DEFAULT, duration);
    }

    function _startLockForDuration(bytes32 tag, uint256 duration) internal {
        if (timeLocks[tag] != 0) revert LockActivated(tag);
        timeLocks[tag] += duration;
    }

    function _lockForever() internal {
        _lockForever(TL_TAG_DEFAULT);
    }

    function _lockForever(bytes32 tag) internal {
        timeLocks[tag] = type(uint256).max;
    }

    function _clearLock() internal {
        _clearLock(TL_TAG_DEFAULT);
    }

    function _clearLock(bytes32 tag) internal {
        timeLocks[tag] = 0;
    }
}
