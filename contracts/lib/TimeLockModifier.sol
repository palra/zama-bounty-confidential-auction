// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

contract TimeLockModifier {
    error LockIsActive(bytes32 tag);
    event LockUpdated(bytes32 indexed tag, uint256 indexed timestamp);
    mapping(bytes32 => uint256) public timeLocks;

    bytes32 internal constant TL_TAG_DEFAULT = bytes32(0x0);

    modifier checkTimeLock() {
        _checkAndUpdateTimeLockTag(bytes32(TL_TAG_DEFAULT));
        _;
    }

    modifier checkTimeLockTag(bytes32 tag) {
        _checkAndUpdateTimeLockTag(tag);
        _;
    }

    function readTimeLockExpirationDate(bytes32 tag) public view returns (uint256) {
        return timeLocks[tag];
    }

    function _checkAndUpdateTimeLockTag(bytes32 tag) internal {
        if (timeLocks[tag] != 0) {
            if (block.timestamp <= timeLocks[tag]) {
                revert LockIsActive(tag);
            }

            _clearLock(tag);
        }
    }

    function _startTimeLockForDuration(uint256 duration) internal {
        _startTimeLockForDuration(TL_TAG_DEFAULT, duration);
    }

    function _startTimeLockForDuration(bytes32 tag, uint256 duration) internal {
        if (timeLocks[tag] != 0) revert LockIsActive(tag);
        timeLocks[tag] += duration;
        _emit(tag);
    }

    function _lockForever() internal {
        _lockForever(TL_TAG_DEFAULT);
    }

    function _lockForever(bytes32 tag) internal {
        timeLocks[tag] = type(uint256).max;
        _emit(tag);
    }

    function _clearLock() internal {
        _clearLock(TL_TAG_DEFAULT);
    }

    function _clearLock(bytes32 tag) internal {
        timeLocks[tag] = 0;
        _emit(tag);
    }

    function _emit(bytes32 tag) private {
        emit LockUpdated(tag, timeLocks[tag]);
    }
}
