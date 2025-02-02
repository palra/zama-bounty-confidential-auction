// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import "fhevm/config/ZamaFHEVMConfig.sol";
import "fhevm/config/ZamaGatewayConfig.sol";
import "fhevm/gateway/GatewayCaller.sol";
import "fhevm-contracts/contracts/token/ERC20/IConfidentialERC20.sol";
import "fhevm-contracts/contracts/utils/EncryptedErrors.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "./lib/HalfEncryptedFenwickTree.sol";
import "./lib/TimeLockModifier.sol";

using HalfEncryptedFenwickTree for HalfEncryptedFenwickTree.Storage;

uint256 constant CALLBACK_MAX_DURATION = 100 seconds;
uint256 constant CALLBACK_MAX_ITERATIONS = 10;
uint256 constant DURATION_BETWEEN_STEPS = 10 minutes;

enum AuctionState {
    WaitDeposit,
    Active,
    Cancelled,
    WithdrawalPending,
    WithdrawalReady
}

struct Bid {
    uint8 price;
    euint64 quantity;
    euint64 deposit;
    bool tombstone;
}

contract ConfidentialSPA is
    SepoliaZamaFHEVMConfig,
    SepoliaZamaGatewayConfig,
    GatewayCaller,
    TimeLockModifier,
    Ownable2Step,
    ReentrancyGuardTransient,
    EncryptedErrors
{
    enum ErrorCodes {
        NO_ERROR,
        TRANSFER_FAILED,
        VALIDATION_ERROR
    }

    struct LastError {
        uint256 errorIndex;
        uint256 at;
    }

    mapping(address => LastError) private lastErrorByAddress;

    bytes32 public constant TL_TAG_COMPUTE_CLEARING = keccak256("compute-clearing-price");
    bytes32 public constant TL_TAG_COMPUTE_CLEARING_STEP = keccak256("compute-clearing-price.step");
    bytes32 public constant TL_TAG_PULL_AUCTIONEER = keccak256("pull-auctioneer");
    bytes32 public constant TL_TAG_RECOVER_AUCTIONEER = keccak256("recover-auctioneer");

    // solhint-disable-next-line func-name-mixedcase
    function TL_TAG_RECOVER_BIDDER(address _bidder) public pure returns (bytes32) {
        return keccak256(abi.encodePacked("recover-bidder", _bidder));
    }

    IConfidentialERC20 public immutable AUCTION_TOKEN;
    IConfidentialERC20 public immutable BASE_TOKEN;
    uint64 public immutable AUCTION_TOKEN_SUPPLY;
    uint256 public immutable AUCTION_END;

    uint64 public immutable MIN_PRICE;
    uint64 public immutable MAX_PRICE;

    euint64 private immutable E_AUCTION_TOKEN_SUPPLY;
    euint128 private immutable EU128_ZERO;
    euint64 private immutable EU64_ZERO;
    euint8 private immutable EU8_ZERO;

    /// @notice When the auction is resolved, the cleartext clearing price will be decrypted and set here.
    uint8 public clearingPriceTick;

    /// @dev When performing the decryption of the clearing price, this is the iterator that will store search state
    /// across successive async decryptions.
    HalfEncryptedFenwickTree.SearchKeyIterator private _searchIterator;

    /// @dev Stores cumulative bid amounts, per index.
    HalfEncryptedFenwickTree.Storage private priceMap;
    /// @dev Stores total bid quantity per price range.
    mapping(uint8 => euint128) private priceToQuantity;
    /// @dev Keeps track of base token deposits. Only used for funds recovery on auction cancellation.
    mapping(address => euint64) private addressToBaseTokenDeposit;
    /// @dev Keeps track of individual bids.
    mapping(address => Bid[]) private addressToBids;
    /// @dev Flag indicating if any bids have been registered.
    bool public hasBids;

    AuctionState public auctionState = AuctionState.WaitDeposit;

    /// @notice Signals that withdrawal is ready.
    event WithdrawalReady(uint8 clearingPriceTick);
    /// @notice Signals readiness for clearing price step search.
    event DecryptClearingPriceNextStepReady();
    /// @notice Signals a new encrypted error to decrypt.
    event ErrorChanged(address indexed user, uint256 errorId);

    error InvalidConstructorArguments();
    error OutOfOrderDecrypt();
    error NotInRequiredState();
    error AuctionEnded();
    error AuctionInProgress();
    error OutOfBounds();
    error BidAlreadyPulled();

    modifier onlyState(AuctionState _state) {
        if (_state != auctionState) {
            revert NotInRequiredState();
        }

        _;
    }

    /// @param _minPrice Minimum price for the auction, expressed with 12 decimals
    /// @param _maxPrice Maximum price for the auction, expressed with 12 decimals
    constructor(
        address _auctioneer,
        IConfidentialERC20 _auctionToken,
        uint64 _auctionTokenSupply,
        IConfidentialERC20 _baseToken,
        uint256 _auctionEnd,
        uint64 _minPrice,
        uint64 _maxPrice
    ) Ownable(_auctioneer) EncryptedErrors(uint8(type(ErrorCodes).max)) {
        if (_auctionTokenSupply == 0) revert InvalidConstructorArguments();
        AUCTION_TOKEN_SUPPLY = _auctionTokenSupply;
        E_AUCTION_TOKEN_SUPPLY = TFHE.asEuint64(_auctionTokenSupply);
        TFHE.allowThis(E_AUCTION_TOKEN_SUPPLY);

        if (_auctionEnd <= block.timestamp) revert InvalidConstructorArguments();
        AUCTION_END = _auctionEnd;

        if (_minPrice >= _maxPrice) revert InvalidConstructorArguments();
        MIN_PRICE = _minPrice;
        MAX_PRICE = _maxPrice;

        AUCTION_TOKEN = _auctionToken;
        BASE_TOKEN = _baseToken;

        priceMap.init();

        EU128_ZERO = TFHE.asEuint128(0);
        TFHE.allowThis(EU128_ZERO);
        EU64_ZERO = TFHE.asEuint64(0);
        TFHE.allowThis(EU64_ZERO);
        EU8_ZERO = TFHE.asEuint8(0);
        TFHE.allowThis(EU8_ZERO);
    }

    function depositAuction() external onlyState(AuctionState.WaitDeposit) onlyOwner {
        _transferIntoContractWithCheck(msg.sender, E_AUCTION_TOKEN_SUPPLY, AUCTION_TOKEN);
        // TODO: check for success, decrypt it then change the state in the callback

        auctionState = AuctionState.Active;
    }

    /// @notice Submit a bid at a given price for an encrypted amount.
    /// @dev Prices are always represented in cleartext. To increase privacy, users are encouraged to submit multiple
    /// zero-quantity bids at random prices.
    /// @param _price Bid price, expressed with 12 decimals.
    /// @param _encryptedQuantity Encrypted bid quantity.
    /// @param _inputProof Encryption proof for encrypted inputs.
    function bid(
        uint64 _price, // TODO: take the tick in parameter instead
        einput _encryptedQuantity,
        bytes calldata _inputProof
    ) external onlyState(AuctionState.Active) nonReentrant {
        if (block.timestamp >= AUCTION_END) revert AuctionEnded();

        // Parse input
        euint64 quantity = TFHE.asEuint64(_encryptedQuantity, _inputProof);
        TFHE.isSenderAllowed(quantity);

        // Validate input
        // `quantity` can't be greater than the auctionned token supply
        ebool invalidQuantity = TFHE.gt(quantity, AUCTION_TOKEN_SUPPLY);
        quantity = TFHE.select(invalidQuantity, EU64_ZERO, quantity);
        euint8 errorCode = _errorDefineIf(invalidQuantity, uint8(ErrorCodes.VALIDATION_ERROR));

        uint8 tick = priceToTick(_price);

        // Compute deposit in base tokens, based on price.12 * quantity.6
        // price * quantity must be a valid base token amount
        euint128 deposit128 = TFHE.div(TFHE.mul(TFHE.asEuint128(quantity), uint128(tickToPrice(tick))), 1e6);
        ebool depositLargerThanMaxSupply = TFHE.gt(deposit128, BASE_TOKEN.totalSupply());
        euint64 deposit = TFHE.select(depositLargerThanMaxSupply, EU64_ZERO, TFHE.asEuint64(deposit128));
        errorCode = _errorChangeIf(depositLargerThanMaxSupply, uint8(ErrorCodes.VALIDATION_ERROR), errorCode);

        ebool success = _transferIntoContractWithCheck(msg.sender, deposit, BASE_TOKEN);
        deposit = TFHE.select(success, deposit, EU64_ZERO); // If the transfer failed, deposit tracker is set to zero
        errorCode = _errorChangeIfNot(success, uint8(ErrorCodes.TRANSFER_FAILED), errorCode);

        // Update data structures
        // If there is an error, perform a no-op
        quantity = TFHE.select(
            TFHE.eq(errorCode, EU8_ZERO), // = no errorm
            quantity,
            EU64_ZERO
        );
        //* should not overflow, add uint64 to uint128
        priceMap.update(tick, TFHE.asEuint128(quantity));

        // Side-effects:

        // - Persist the bid
        TFHE.allowThis(deposit);
        TFHE.allowThis(quantity);
        addressToBids[msg.sender].push(Bid({ price: tick, quantity: quantity, deposit: deposit, tombstone: false }));

        // - Update quantity accumulator at a given tick
        if (!TFHE.isInitialized(priceToQuantity[tick])) {
            priceToQuantity[tick] = EU128_ZERO;
        }
        //* should not overflow: add uint64 to uint128
        priceToQuantity[tick] = TFHE.add(priceToQuantity[tick], quantity);
        TFHE.allowThis(priceToQuantity[tick]);

        // - Update address to base token deposit map, in case of auction cancellation
        if (!TFHE.isInitialized(addressToBaseTokenDeposit[msg.sender])) {
            addressToBaseTokenDeposit[msg.sender] = EU64_ZERO;
        }
        //* should not overflow: deposit is checked to be a valid ConfERC20 value, whose totalSupply can't exceed uint64
        addressToBaseTokenDeposit[msg.sender] = TFHE.add(addressToBaseTokenDeposit[msg.sender], deposit);
        TFHE.allowThis(addressToBaseTokenDeposit[msg.sender]);

        // - At least one bid has been registered, mark it
        hasBids = true;

        // - Cleanup
        _setError(errorCode);
        TFHE.cleanTransientStorage();
    }

    /// @notice In case of emergency, cancels the auction and activate recovery functions.
    /// @dev Only the owner (auctioneer) can cancel the auction.
    function cancel() external onlyOwner {
        if (auctionState == AuctionState.Cancelled) revert NotInRequiredState();
        if (auctionState == AuctionState.WithdrawalPending) revert NotInRequiredState();
        if (auctionState == AuctionState.WithdrawalReady) revert NotInRequiredState();

        auctionState = AuctionState.Cancelled;
    }

    /// @notice When the auction timed out, initiate the decryption of the withdrawal state.
    /// @dev Initiating the decryption can only be done while no current withdrawal decryption is pending. The process
    /// can be restarted after a timeout, but will be definitely locked after the full decryption succeeded.
    /// Can be called by anyone - for automation purposes.
    function startWithdrawalDecryption()
        external
        onlyState(AuctionState.Active)
        checkTimeLockTag(TL_TAG_COMPUTE_CLEARING)
    {
        if (block.timestamp < AUCTION_END) revert NotInRequiredState();

        // No bids, no clearing price. Goto Cancelled state to allow recovery of funds.
        if (!hasBids) {
            auctionState = AuctionState.Cancelled;
            return;
        }

        auctionState = AuctionState.WithdrawalPending;

        _searchIterator = priceMap.startSearchKey(AUCTION_TOKEN_SUPPLY);
        priceMap.stepSearchKey(_searchIterator, 0);

        // Prevent any restart of the computation during the estimated maximum duration of the whole process.
        _startTimeLockForDuration(
            TL_TAG_COMPUTE_CLEARING_STEP,
            CALLBACK_MAX_DURATION * CALLBACK_MAX_ITERATIONS + DURATION_BETWEEN_STEPS * CALLBACK_MAX_ITERATIONS
        );
    }

    function isRunningWithdrawalDecryption() public view returns (bool) {
        return auctionState == AuctionState.WithdrawalPending;
    }

    /// @notice When the withdrawal decryption was initiated, steps through the decryption process.
    /// @dev Decryption is an asynchronous process. While the contract waits for the decryption, the method is locked to
    /// prevent race conditions. The lock is freed as soon as the decryption result is persisted in the contract or
    /// after a timeout.
    function stepWithdrawalDecryption()
        external
        onlyState(AuctionState.WithdrawalPending)
        checkTimeLockTag(TL_TAG_COMPUTE_CLEARING_STEP)
    {
        uint256[] memory cts = new uint256[](1);
        bytes4 selector;
        if (TFHE.isInitialized(_searchIterator.foundIdx)) {
            cts[0] = Gateway.toUint256(_searchIterator.foundIdx);
            selector = this.callbackWithdrawalDecryptionFinal.selector;
        } else {
            cts[0] = Gateway.toUint256(_searchIterator.idx);
            selector = this.callbackWithdrawalDecryptionStep.selector;
        }

        Gateway.requestDecryption(cts, selector, 0, block.timestamp + CALLBACK_MAX_DURATION, false);
        // Prevent any decryption while we're waiting for the Gateway.
        _startTimeLockForDuration(TL_TAG_COMPUTE_CLEARING_STEP, CALLBACK_MAX_DURATION);
    }

    function callbackWithdrawalDecryptionStep(
        uint256,
        uint8 idx
    ) external onlyState(AuctionState.WithdrawalPending) onlyGateway {
        priceMap.stepSearchKey(_searchIterator, idx);
        // Release the lock on the step trigger, so we can call it again.
        _clearLock(TL_TAG_COMPUTE_CLEARING_STEP);
        emit DecryptClearingPriceNextStepReady();
    }

    function callbackWithdrawalDecryptionFinal(
        uint256,
        uint8 found
    ) external onlyState(AuctionState.WithdrawalPending) onlyGateway {
        clearingPriceTick = found;
        // The clearing price has been found, we'll never need to compute it again. Lock clearing price compute forever.
        _lockForever(TL_TAG_COMPUTE_CLEARING);
        _lockForever(TL_TAG_COMPUTE_CLEARING_STEP);

        if (found == 0) {
            auctionState = AuctionState.Cancelled;
            return;
        }

        emit WithdrawalReady(clearingPriceTick);
        auctionState = AuctionState.WithdrawalReady;
    }

    /// @notice When the auction is resolved, pull funds owed to the auctioneer.
    /// @dev Can be called by anyone, the funds will always be transfered to the auctioneer - for automation purposes.
    function pullAuctioneer()
        external
        onlyState(AuctionState.WithdrawalReady)
        checkTimeLockTag(TL_TAG_PULL_AUCTIONEER)
    {
        _lockForever(TL_TAG_PULL_AUCTIONEER);

        euint64 totalTokens = TFHE.asEuint64(AUCTION_TOKEN_SUPPLY);
        address auctioneer = owner();

        // Return non-allocated tokens
        //* should not overflow, totalTokens is <= uint64.max
        euint64 auctionAllocated = TFHE.asEuint64(TFHE.min(totalTokens, priceMap.totalValue()));
        euint64 auctionToTransfer = TFHE.sub(totalTokens, auctionAllocated);
        _transferTo(auctioneer, auctionToTransfer, AUCTION_TOKEN);

        // Pull base tokens
        euint64 baseToTransfer = TFHE.asEuint64(
            // convert from 12 dec. to 6 dec.
            TFHE.div(TFHE.mul(TFHE.asEuint128(auctionAllocated), tickToPrice(clearingPriceTick)), 1e6)
        );
        _transferTo(auctioneer, baseToTransfer, BASE_TOKEN);

        TFHE.cleanTransientStorage();
    }

    /// @notice When the auction is resolved, pull funds owed by a given bidde for a specific bid.
    /// @dev Can be called by anyone, the funds will always be transfered to the auctioneer - for automation purposes.
    function pullBid(address _bidder, uint256 _index) external nonReentrant {
        _pullBidByIndex(_bidder, _index);
    }

    /// TODO: to be removed.
    function popBid(address bidder) external nonReentrant {
        if (addressToBids[bidder].length == 0) revert OutOfBounds();
        _pullBidByIndex(bidder, addressToBids[bidder].length - 1);
    }

    function _pullBidByIndex(address _bidder, uint256 _index) private {
        if (_index >= addressToBids[_bidder].length) revert OutOfBounds();
        Bid storage _bid = addressToBids[_bidder][_index];
        if (_bid.tombstone) {
            revert BidAlreadyPulled();
        }

        euint64 auctionToTransfer = EU64_ZERO;
        euint64 baseToTransfer = EU64_ZERO;

        // No need to obfuscate `if` branches, the price is cleartext anyways.

        // Comparison order is reversed, because ticks and price orders are inverted for storage purposes.
        if (_bid.price > clearingPriceTick) {
            // Offer rejected, refunding deposit
            baseToTransfer = _bid.deposit;
            // Saving some gas by deleting the now unused priceToQuantity mapping
            // TODO: check gas refund
            priceToQuantity[_bid.price] = euint128.wrap(0);
        } else if (_bid.price < clearingPriceTick) {
            // Offer accepted, below clearing price = entirely fulfilled
            uint128 clearingPrice = uint128(tickToPrice(clearingPriceTick));

            auctionToTransfer = _bid.quantity;
            euint128 eQuantity = TFHE.asEuint128(_bid.quantity);
            // Claring price is lower than the quantity previously secured, refund remaining.
            //* should not overflow: clearingPrice < _bid.price => (_bid.quantity * clearingPrice) / 1e6 < _bid.deposit
            baseToTransfer = TFHE.sub(_bid.deposit, TFHE.asEuint64(TFHE.div(TFHE.mul(eQuantity, clearingPrice), 1e6)));

            // No need to update priceToQuantity: we're guaranteed to never send more than available at that range price
            // because all bids above the clearingPrice are entirely fulfilled.

            // Saving some gas by deleting the now unused priceToQuantity mapping
            // TODO: check gas refund
            priceToQuantity[_bid.price] = euint128.wrap(0);
        } else {
            uint128 clearingPrice = uint128(tickToPrice(clearingPriceTick));
            // Offer accepted, at clearing price = at least partially fulfilled
            euint64 totalTokens = E_AUCTION_TOKEN_SUPPLY;

            // Compute amount of tokens that overflow besides the auction token supply.
            //* should not underflow: priceMap.query(x) <= priceMap.totalValue() - properties of the Fenwick tree
            euint128 quantityOverAuctionAvailable = TFHE.sub(
                priceMap.query(clearingPriceTick), // cumulative qty at clearing price
                TFHE.min(totalTokens, priceMap.totalValue()) // total allocated tokens
            );

            // Substract without underflow, clamp at 0.
            euint64 allocationAtPrice = TFHE.select(
                TFHE.ge(priceToQuantity[clearingPriceTick], quantityOverAuctionAvailable),
                //* should not overflow: TOOD: prove it ._.
                TFHE.asEuint64(TFHE.sub(priceToQuantity[clearingPriceTick], quantityOverAuctionAvailable)),
                EU64_ZERO
            );

            // In case of competing bids at the same price, first arrived first served.
            auctionToTransfer = TFHE.min(allocationAtPrice, _bid.quantity);
            //* should not overflow/underflow: auctionToTransfer <= _bid.quantity and _bid.quantity * _bid.price is
            //* known to be <= than uint64.max, checked in bid()
            baseToTransfer = TFHE.asEuint64(
                TFHE.div(TFHE.mul(TFHE.sub(TFHE.asEuint128(_bid.quantity), auctionToTransfer), clearingPrice), 1e6)
            );

            // Make sure future pulls at the same price tick will not compute available funds based on already withdrawn
            // funds.
            //* should not underflow: auctionToTransfer <= allocationAtPrice <= priceToQuantity[clearingPriceTick]
            priceToQuantity[clearingPriceTick] = TFHE.sub(priceToQuantity[clearingPriceTick], auctionToTransfer);
            TFHE.allowThis(priceToQuantity[clearingPriceTick]);
        }

        _bid.tombstone = true;

        _transferTo(_bidder, auctionToTransfer, AUCTION_TOKEN);
        _transferTo(_bidder, baseToTransfer, BASE_TOKEN);

        TFHE.cleanTransientStorage();
    }

    /// @notice When in recover state, recover funds sent by the auctioneer.
    function recoverAuctioneer()
        external
        onlyState(AuctionState.Cancelled)
        checkTimeLockTag(TL_TAG_RECOVER_AUCTIONEER)
    {
        _lockForever(TL_TAG_RECOVER_AUCTIONEER);

        euint64 auctionToTransfer = TFHE.asEuint64(AUCTION_TOKEN_SUPPLY);
        _transferTo(owner(), auctionToTransfer, AUCTION_TOKEN);

        TFHE.cleanTransientStorage();
    }

    /// @notice When in recover state, recover funds sent by the specified bidder.
    /// @param _bidder The address of the bidder
    function recoverBidder(
        address _bidder
    ) external onlyState(AuctionState.Cancelled) checkTimeLockTag(TL_TAG_RECOVER_BIDDER(_bidder)) {
        _lockForever(TL_TAG_RECOVER_BIDDER(_bidder));

        euint64 baseToTransfer = TFHE.isInitialized(addressToBaseTokenDeposit[_bidder])
            ? addressToBaseTokenDeposit[_bidder]
            : TFHE.asEuint64(0);
        _transferTo(_bidder, baseToTransfer, BASE_TOKEN);

        TFHE.cleanTransientStorage();
    }

    // Price transformation

    /// @dev Transforms a price in the interval [MIN_PRICE, MAX_PRICE) to a uint8 in the interval [255, 0). Performs a
    /// linear interpolation, which is not ideal for financial applications.
    /// @param price The price to transform.
    /// @return The transformed price as a uint8 tick.
    function priceToTick(uint64 price) public view returns (uint8) {
        if (price <= MIN_PRICE || price > MAX_PRICE) revert OutOfBounds();

        uint64 ratio = ((MAX_PRICE - price) * (type(uint8).max)) / (MAX_PRICE - MIN_PRICE);
        return uint8(ratio + 1);
    }

    /// @dev Transforms a uint8 in the interval [255, 0) back to a price in the interval [MIN_PRICE, MAX_PRICE).
    /// @param tick The uint8 to transform back.
    /// @return The transformed price as a uint256.
    function tickToPrice(uint8 tick) public view returns (uint64) {
        if (tick == 0) revert OutOfBounds();

        uint64 ratio = ((tick - 1) * (MAX_PRICE - MIN_PRICE)) / (type(uint8).max);
        return MAX_PRICE - ratio;
    }

    // Encrypted transfer utils

    function _transferIntoContractWithCheck(
        address _from,
        euint64 _amount,
        IConfidentialERC20 _token
    ) internal returns (ebool success) {
        euint64 balanceBefore = _token.balanceOf(address(this));
        if (!TFHE.isInitialized(balanceBefore)) {
            balanceBefore = TFHE.asEuint64(0);
        }

        TFHE.allowTransient(_amount, address(_token));
        _token.transferFrom(_from, address(this), _amount);
        success = TFHE.or(TFHE.eq(_amount, 0), TFHE.ne(balanceBefore, _token.balanceOf(address(this))));
    }

    function _transferTo(address _to, euint64 _amount, IConfidentialERC20 _token) internal {
        TFHE.allowTransient(_amount, address(_token));
        _token.transfer(_to, _amount);
    }

    // Error handling

    /// @notice Reads the last encrypted error for the caller.
    /// @return errorCode The encrypted error code.
    /// @return at The timestamp at which the error was raised.
    function getLastEncryptedError() external view returns (euint8 errorCode, uint256 at) {
        LastError storage err = lastErrorByAddress[msg.sender];
        errorCode = _errorGetCodeEmitted(err.errorIndex);
        at = err.at;
    }

    function getEncryptedErrorIndex(uint256 errorIndex) external view returns (euint8 errorCode) {
        return _errorGetCodeEmitted(errorIndex);
    }

    function _setError(euint8 errorCode) private {
        TFHE.allow(errorCode, msg.sender);
        uint256 errorIndex = _errorSave(errorCode);
        lastErrorByAddress[msg.sender] = LastError({ errorIndex: _errorSave(errorCode), at: block.timestamp });
        emit ErrorChanged(msg.sender, errorIndex);
    }
}
