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
    event Total(uint128);

    constructor() {
        tree.init();
    }

    function update(uint8 key, einput encryptedQuantity, bytes calldata inputProof) external {
        euint128 quantity = TFHE.asEuint128(encryptedQuantity, inputProof);
        tree.update(key, quantity);
    }

    euint128 public queryResult;

    function queryKey(uint8 key) external returns (euint128) {
        queryResult = tree.query(key);
        return queryResult;
    }

    function totalValue() external view returns (euint128) {
        return tree.totalValue();
    }

    function peekTreeAtKey(uint8 key) public view returns (euint128) {
        return tree.tree[key];
    }

    HalfEncryptedFenwickTree.SearchKeyIterator public searchIterator;

    function isRunningSearchKey() public view returns (bool) {
        return !TFHE.isInitialized(searchIterator.foundIdx);
    }

    function startSearchKey(uint128 atValue) external {
        searchIterator = tree.startSearchKey(atValue);
        tree.stepSearchKey(searchIterator, 0);
    }

    function startSearchKeyFallbackNotFound(uint128 atValue) external {
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
