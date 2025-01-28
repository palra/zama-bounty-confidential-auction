```mermaid
---
title: Single-price Auction with Half-Encrypted Fenwick Tree
config:
  layout: elk
---
stateDiagram-v2
    [*] --> Active

    Active --> Active: bid(price, qty)
    Active --> Cancelled: cancel() onlyAuctioneer

    state CheckBidders <<choice>>

    CheckBidders --> Cancelled: _no bids_
    CheckBidders --> Withdrawal: else

    Active --> CheckBidders: _timed out_

    state Withdrawal {
      state WithdrawalDecrypt <<fork>>
      state WithdrawalDecrypted <<join>>

      [*] --> WithdrawalDecrypt

      WithdrawalDecrypt --> ClearingPrice
      state ClearingPrice {
        state ClearingPrice_IsFinished <<choice>>
        [*] --> ClearingPriceComputing
        ClearingPriceComputing --> ClearingPriceDecrypt: stepCompute()
        ClearingPriceDecrypt --> ClearingPrice_IsFinished: _wait decryption - set clearingPrice_
        ClearingPrice_IsFinished --> [*]: _clearingPrice is defined_
        ClearingPrice_IsFinished --> ClearingPriceComputing : _else_
      }
      ClearingPrice --> WithdrawalDecrypted

      WithdrawalDecrypt --> TotalQuantity
      state TotalQuantity {
        [*] --> TotalQuantityDecrypt
        TotalQuantityDecrypt --> TotalQuantityWait: decryptTotalQuantity()
        TotalQuantityWait --> [*]: _wait decryption - set totalQuantity_
      }
      TotalQuantity --> WithdrawalDecrypted

      WithdrawalDecrypted --> WithdrawalReady

      state WithdrawalReady {
        [*] --> AuctioneerWaiting
        AuctioneerWaiting --> AuctioneerWithdrawn: pullAuctioneer()
        AuctioneerWithdrawn --> [*]
        --
        [*] --> BidderWaiting
        BidderWaiting --> BidderWithdrawn: pullBid(bidIdx)
        BidderWithdrawn --> [*]
      }

      WithdrawalReady --> [*]
    }

    Withdrawal --> [*]

    state Cancelled {
        [*] --> CancelledAuctioneerWaiting
        CancelledAuctioneerWaiting --> CancelledAuctioneerWithdrawn: recoverTokensForSale()
        CancelledAuctioneerWithdrawn --> [*]
        --
        [*] --> CancelledBidderWaiting
        CancelledBidderWaiting --> CancelledBidderRecovered: recoverBids()
        CancelledBidderRecovered --> [*]
    }

    Cancelled --> [*]
```
