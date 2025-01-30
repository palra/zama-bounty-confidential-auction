// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import "../lib/HalfEncryptedFenwickTree.sol";
import "fhevm/config/ZamaFHEVMConfig.sol";
import "fhevm/config/ZamaGatewayConfig.sol";
import "fhevm/gateway/GatewayCaller.sol";
import "hardhat/console.sol";

contract MockHEFTImpl is SepoliaZamaFHEVMConfig, SepoliaZamaGatewayConfig, GatewayCaller {
    using HalfEncryptedFenwickTree for HalfEncryptedFenwickTree.Storage;

    HalfEncryptedFenwickTree.Storage tree;

    event Found(uint8);
    event Total(uint64);

    constructor() {
        tree.init();
    }

    function update(uint8 key, einput encryptedQuantity, bytes calldata inputProof) external {
        euint64 quantity = TFHE.asEuint64(encryptedQuantity, inputProof);
        tree.update(key, quantity);
    }

    euint64 public queryResult;

    function queryKey(uint8 key) external returns (euint64) {
        queryResult = tree.query(key);
        return queryResult;
    }

    function totalValue() external view returns (euint64) {
        return tree.totalValue();
    }

    function peekTreeAtKey(uint8 key) public view returns (euint64) {
        return tree.tree[key];
    }

    HalfEncryptedFenwickTree.SearchKeyIterator public searchIterator;

    function isRunningSearchKey() public view returns (bool) {
        return !TFHE.isInitialized(searchIterator.foundIdx);
    }

    function startSearchKey(uint64 atValue) external {
        searchIterator = tree.startSearchKey(atValue);
        tree.stepSearchKey(searchIterator, 0);
    }

    function startSearchKeyFallbackNotFound(uint64 atValue) external {
        searchIterator = tree.startSearchKey(atValue);
        searchIterator.fallbackIdx = TFHE.asEuint8(0);
        tree.stepSearchKey(searchIterator, 0);
    }

    function stepSearchKey() external {
        uint256[] memory cts = new uint256[](1);
        cts[0] = Gateway.toUint256(searchIterator.idx);
        Gateway.requestDecryption(cts, this.callbackSearchKeyStep.selector, 0, block.timestamp + 100, false);
    }

    function callbackSearchKeyStep(uint256, uint8 idx) public onlyGateway {
        tree.stepSearchKey(searchIterator, idx);
    }

    function searchResult() external view returns (euint8) {
        return searchIterator.foundIdx;
    }
}
