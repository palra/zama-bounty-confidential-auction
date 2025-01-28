// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import "fhevm/config/ZamaFHEVMConfig.sol";
import "fhevm/config/ZamaGatewayConfig.sol";
import "fhevm/gateway/GatewayCaller.sol";

import "./lib/HalfEncryptedFenwickTree.sol";
import "./lib/TimeLockModifier.sol";

uint256 constant CALLBACK_MAX_DURATION = 100 seconds;
uint256 constant CALLBACK_MAX_ITERATIONS = 10;

contract ConfidentialSPA is SepoliaZamaFHEVMConfig, SepoliaZamaGatewayConfig, GatewayCaller, TimeLockModifier {
    using HalfEncryptedFenwickTree for HalfEncryptedFenwickTree.Storage;
    HalfEncryptedFenwickTree.Storage priceMap;

    uint128 public immutable tokenSupply;
    uint256 public immutable auctionEnd;

    /// @notice When the auction is resolved and the clearance price successfully decrypted, the cleartext clearance
    /// price will be set here.
    uint8 public clearancePrice;

    event AuctionResolved(uint8 clearancePrice);

    error InvalidConstructorArguments();
    error OutOfOrderDecrypt();

    constructor(uint128 _tokenSupply, uint256 _auctionEnd) {
        if (_tokenSupply == 0) revert InvalidConstructorArguments();
        tokenSupply = _tokenSupply;

        if (_auctionEnd < block.timestamp) revert InvalidConstructorArguments();
        auctionEnd = _auctionEnd;

        priceMap.init();
    }

    function addBid(uint256 price, einput encryptedQuantity, bytes calldata inputProof) external checkLock {
        euint128 quantity = TFHE.asEuint128(encryptedQuantity, inputProof);
        TFHE.isSenderAllowed(quantity);
        priceMap.update(priceToUint8(price), quantity);
    }

    HalfEncryptedFenwickTree.SearchKeyIterator _searchIterator;

    bytes32 private constant TL_TAG_COMPUTE_CLEARANCE = keccak256("computeClearancePrice");

    function startComputeClearancePrice() external checkLockTag(TL_TAG_COMPUTE_CLEARANCE) {
        _lockForever();
        _searchIterator = priceMap.startSearchKey(tokenSupply);
        priceMap.stepSearchKey(_searchIterator, 0);
    }

    function isRunningComputeClearancePrice() public view returns (bool) {
        return clearancePrice == 0;
    }

    bytes32 private constant TL_TAG_COMPUTE_CLEARANCE_STEP = keccak256("stepComputeClearancePrice");

    function stepComputeClearancePrice() external checkLockTag(TL_TAG_COMPUTE_CLEARANCE_STEP) {
        uint256[] memory cts = new uint256[](1);
        bytes4 selector;
        if (TFHE.isInitialized(_searchIterator.foundIdx)) {
            cts[0] = Gateway.toUint256(_searchIterator.foundIdx);
            selector = this.callback_stepComputeClearancePrice_end.selector;
        } else {
            cts[0] = Gateway.toUint256(_searchIterator.idx);
            selector = this.callback_stepComputeClearancePrice_step.selector;
        }

        Gateway.requestDecryption(cts, selector, 0, block.timestamp + CALLBACK_MAX_DURATION, false);
        _startLockForDuration(TL_TAG_COMPUTE_CLEARANCE_STEP, CALLBACK_MAX_DURATION);
    }

    function callback_stepComputeClearancePrice_step(uint256, uint8 idx) public onlyGateway {
        priceMap.stepSearchKey(_searchIterator, idx);
        _clearLock(TL_TAG_COMPUTE_CLEARANCE_STEP);
    }

    function callback_stepComputeClearancePrice_end(uint256, uint8 found) public onlyGateway {
        clearancePrice = found;
        emit AuctionResolved(clearancePrice);
        _lockForever(TL_TAG_COMPUTE_CLEARANCE);
    }

    // Price transformation

    uint256 public constant MIN_PRICE = 1e9;
    uint256 public constant MAX_PRICE = 1e13;
    error PriceOutOfBounds();

    /// @dev Transforms a price in the interval [MIN_PRICE, MAX_PRICE) to a uint8 in the interval [255, 0).
    /// @param price The price to transform.
    /// @return The transformed price as a uint8.
    function priceToUint8(uint256 price) public pure returns (uint8) {
        // Ensure the price is within the defined range
        if (price < MIN_PRICE || price >= MAX_PRICE) revert PriceOutOfBounds();

        // Calculate the ratio of the price to the maximum price
        uint256 ratio = ((MAX_PRICE - price) * (type(uint8).max)) / (MAX_PRICE - MIN_PRICE);
        // Since Solidity will truncate the decimal part when assigning a uint256 to a uint8,
        // we need to make sure the result of the division is already in the range [0, 255]
        return uint8(ratio);
    }

    /// @dev Transforms a uint8 in the interval [255, 0) back to a price in the interval [MIN_PRICE, MAX_PRICE).
    /// @param uint8Value The uint8 to transform back.
    /// @return The transformed price as a uint256.
    function uint8ToPrice(uint8 uint8Value) public pure returns (uint256) {
        // Calculate the ratio of the uint8 value to the maximum uint8 value
        uint256 ratio = (uint8Value * (MAX_PRICE - MIN_PRICE)) / (type(uint8).max);
        // The price is inversely related to the uint8 value, so we subtract the ratio from MAX_PRICE
        return MAX_PRICE - ratio;
    }
}
