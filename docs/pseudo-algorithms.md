# Pseudocode algorithms

## Withdrawal

### Bid

```python
class Bid:
  owner: address
  amount: int
  price: int

class ConfidentialSPA:
  auctioneer: address

  total_tokens: int
  auction_token: IConfidentialERC20
  base_token: IConfidentialERC20

  total_bids: int
  price_to_cumulative: FenwickTree[float, int]
  price_to_qty: HashMap[float, int]
  settlement_price: float

  @non_reentrant
  def pull_bid(self, bid: Bid):
    auction_to_transfer = 0
    base_to_refund = 0
    # Offer rejected
    if bid.price > settlement_price:
      base_to_refund = bid.amount
    # Offer accepted, below settlement price = entirely fulfilled
    else if bid.price < settlement_price:
      auction_to_transfer = bid.amount
      # Initial deposit will be higher than the current settlement price, refunding the difference
      base_to_transfer = (bid.quantity * bid.price) - (bid.quantity * settlement_price)
    # Offer accepted, at settlement price = at least partially fulfilled
    else:
      allocated_for_price = price_to_qty[settlement_price] - (price_to_cumulative[settlement_price] - min(total_bids, total_tokens))
      auction_to_transfer = (bid.amount * allocated_for_price) / price_to_qty[settlement_price] # TODO: handle leftovers
      base_to_refund = (bid.amount * settlement_price) - (auction_to_transfer * settlement_price)

    auction_token.transfer(bid.owner, auction_to_transfer)
    base_token.transfer(bid.owner, base_to_refund)

  @non_reentrant
  @only_auctioneer
  def pull_auctioneer():
    auction_allocated = min(total_tokens, total_bids)
    auction_token.transfer(
      auctioneer,
      total_tokens - auction_allocated
    )
    base_token.transfer(
      auctioneer,
      auction_allocated * settlement_price
    )

```

> Whoopsie. In `pull_bid`, `price_to_qty[settlement_price]` is an encrypted value, but TFHE supports only division with
> a cleartext denominator. We can't perform proportional attribution if multiple bidders came across the same price
> range. At the moment, we will just proceed in a first arrived first served fashion.
