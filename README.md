# Zama Bounty Program - Confidential Single-Price Auction

My submission for the [Zama Bounty Program on the fhEVM, season 7](https://github.com/zama-ai/bounty-program/issues/136).

[You can find some information on design considerations in the related documentation file.](./docs/design-considerations.md)

## User guide

### Putting a token to auction

If you have tokens you want to put to auction (referred as the **auctioneer**):

1. Deploy the auction contract with your base parameters:
   ```ts
   const AUCTION_SUPPLY = 100_000n;
   const ConfidentialSPA = await ethers.getContractFactory("ConfidentialSPA");
   const auction = await ConfidentialSPA.deploy(
    signer.address,            // Your address
    tokenAuction.address,      // The address of the ConfidentialERC20 token you want to put to auction
    AUCTION_SUPPLY,            // The amount of tokens you're putting to auction
    tokenBase.address,         // The base currency on which bidders will have to deposit
    time.latest() + 1 * month, // The timestamp at which the auction will be closed
    0n,                        // Price discretization: minimum price to submit a bid, uint64 with 12 dec. points
    10n ** 7n                  // Maximum price, uint64 with 12 dec. points
   );
   ```

2. Approve transfer of the auctionned tokens, deposit the funds and check there are no errors
   ```ts
    const input = fhevm.createEncryptedInput(await tokenAuction.getAddress(), signer.address);
    input.add64(AUCTION_SUPPLY);
    const encryptedInput = await input.encrypt();

    await token.connect(signer)[
      "approve(address,bytes32,bytes)"
    ](await auction.getAddress(), encryptedInput.handles[0], encryptedInput.inputProof);

    await auction.depositAuction();

    const [eErrorCode] = await auction.getLastEncryptedError();
    const errorCode = await reencryptEuint8(..., eErrorCode, await auction.getAddress());
    // errorCode === 0n
   ```

### Participate to an auction

To participate to an auction at a given `price` for a given `quantity`:

1. Set allowance to the base token at least at `price * quantity`.
2. Create some no-op bids to submit alongside your original bid to preserve anonymity on your prices.
   ```ts
   async function bid(price: number | bigint, amount: number | bigint, signer: Signer) {
     const input = fhevm.createEncryptedInput(contractAddress, await signer.getAddress());
     input.add64(amount);

     const encryptedInput = await input.encrypt();
     return await contract.connect(signer).bid(price, encryptedInput.handles[0], encryptedInput.inputProof);
   }

   function randomPrice() {
     return Math.floor(Math.random() * (1e7 - 1)); // Depends on the parameters of the auction
   }

   const ANONYMITY_ROUNDS = 3;
   const bids = [
     { price, quantity },
     ...Array(ANONYMITY_ROUNDS).fill().map(() => ({ price: randomPrice(), quantity: 0 }))
   ].sort((a, b) => a.price - b.price);

   for (const { price, quantity } of bids) {
     await bid(price, quantity, signer);
   }
   ```
  > In this implementation, **bids cannot be cancelled** unless the auctioneer cancels the whole auction.

### Decrypt the Settlement Price

Once the auction time has passed, we must go through the decryption process. This can be called by anyone, for automation purposes, as it's just a
matter of iteratively trigger decryptions by the co-processor:
```ts
await (await contract.startWithdrawalDecryption()).wait();

if ((await contract.auctionState()) === 2n) { // 2 = Cancelled, there was no bid registered
  return;
}

while (await contract.isRunningWithdrawalDecryption()) {
  // Wait for the step lock to be available, trivial impl.
  while(true) {
    const lockExpirationDate = await contract.readTimeLockExpirationDate(await contract.TL_TAG_COMPUTE_SETTLEMENT_STEP());
    if (lockExpirationDate === 0n || (+new Date() / 1000) > lockExpirationDate) {
      break;
    }

    await setTimeout(5000);
  }

  // Call the next step
  (await contract.stepWithdrawalDecryption()).wait();
}
```

### Withdraw Funds

Same as before, these methods can be called by anyone but will still redirect the funds to the concerned user:

```ts
// Auctioneer
await contract.pullAuctioneer();

// Bidder
const bidder = await signer.getAddress();
const bidsQuantity = await contract.getBidsLengthByBidder(bidder);
for (let i = 0; i < bidsQuantity; i++) {
  await contract.pullBid(bidder, i);
}
```

Bidders that want to preserve anonymity on the price they proposed can sequentially decrypt all the bids they submitted, including their no-ops.
If anonymity is not a concern after the auction resolution, they can specifically pull the no-op bids, leaving the others untouched.n

### Cancel an Auction

Anytime before the auction ends, the auctioneer may cancel the auction. When that happens, all users can withdraw their locked funds:

```ts
// Auctioneer
await contract.connect(auctioneer.signer).cancel();
await contract.recoverAuctioneer();

// Bidder
await contract.recoverBids();
```

## Local development guide

### Pre Requisites

Install [pnpm](https://pnpm.io/installation)

Before being able to run any command, you need to create a `.env` file and set a BIP-39 compatible mnemonic as the `MNEMONIC`
environment variable. You can follow the example in `.env.example` or start with the following command:

```sh
cp .env.example .env
```

If you don't already have a mnemonic, you can use this [website](https://iancoleman.io/bip39/) to generate one. An alternative, if you have [foundry](https://book.getfoundry.sh/getting-started/installation) installed is to use the `cast wallet new-mnemonic` command.

Then, install all needed dependencies - please **_make sure to use Node v20_** or more recent:

```sh
pnpm install
```

### Compile

Compile the smart contracts with Hardhat:

```sh
pnpm compile
```

### TypeChain

Compile the smart contracts and generate TypeChain bindings:

```sh
pnpm typechain
```

### Test

Run the tests with Hardhat - this will run the tests on a local hardhat node in mocked mode (i.e the FHE operations and decryptions will be simulated by default):

```sh
pnpm test
```

### Lint Solidity

Lint the Solidity code:

```sh
pnpm lint:sol
```

### Lint TypeScript

Lint the TypeScript code:

```sh
pnpm lint:ts
```


### Clean

Delete the smart contract artifacts, the coverage reports and the Hardhat cache:

```sh
pnpm clean
```

### Mocked mode

The mocked mode allows faster testing and the ability to analyze coverage of the tests. In this mocked version,
encrypted types are not really encrypted, and the tests are run on the original version of the EVM, on a local hardhat
network instance. To run the tests in mocked mode, you can use directly the following command:

```bash
pnpm test
```

You can still use all the usual specific [hardhat network methods](https://hardhat.org/hardhat-network/docs/reference#hardhat-network-methods), such as `evm_snapshot`, `evm_mine`, `evm_increaseTime`, etc, which are very helpful in a testing context. Another useful hardhat feature, is the [console.log](https://hardhat.org/hardhat-network/docs/reference#console.log) function which can be used in fhevm smart contracts in mocked mode as well.

To analyze the coverage of the tests (in mocked mode necessarily, as this cannot be done on the real fhEVM node), you
can use this command :

```bash
pnpm coverage
```

Then open the file `coverage/index.html`. You can see there which line or branch for each contract which has been
covered or missed by your test suite. This allows increased security by pointing out missing branches not covered yet by
the current tests.

Finally, a new fhevm-specific feature is available in mocked mode: the `debug.decrypt[XX]` functions, which can decrypt directly any encrypted value. Please refer to the [utils.ts](https://github.com/zama-ai/fhevm/blob/main/test/utils.ts#L87-L317) file for the corresponding documentation.

> [!Note]
> Due to intrinsic limitations of the original EVM, the mocked version differs in rare edge cases from the real fhEVM, the main difference is the gas consumption for the FHE operations (native gas is around 20% underestimated in mocked mode). This means that before deploying to production, developers should still run the tests with the original fhEVM node, as a final check - i.e in non-mocked mode (see next section).

### Non-mocked mode - Sepolia

To run your test on a real fhevm node, you can use the coprocessor deployed on the Sepolia test network. To do this, ensure you are using a valid value `SEPOLIA_RPC_URL` in your `.env` file. You can get free Sepolia RPC URLs by creating an account on services such as [Infura](https://www.infura.io/) or [Alchemy](https://www.alchemy.com/). Then you can use the following command:

```bash
npx hardhat test [PATH_TO_YOUR_TEST] --network sepolia
```

The `--network sepolia` flag will make your test run on a real fhevm coprocessor. Obviously, for the same tests to pass on Sepolia, contrarily to mocked mode, you are not allowed to use any hardhat node specific method, and neither use any of the `debug.decrypt[XX]` functions.

> [!Note]
> For this test to succeed, first ensure you set your own private `MNEMONIC` variable in the `.env` file and then  ensure you have funded your test accounts on Sepolia. For example you can use the following command to get the corresponding private keys associated with the first `5` accounts derived from the mnemonic:
```
npx hardhat get-accounts --num-accounts 5
```
This will let you add them to the Metamask app, to easily fund them from your personal wallet.

If you don't own already Sepolia test tokens, you can for example use a free faucet such as [https://sepolia-faucet.pk910.de/](https://sepolia-faucet.pk910.de/).

Another faster way to test the coprocessor on Sepolia is to simply run the following command:
```
pnpm deploy-sepolia
```
This would automatically deploy an instance of the `MyConfidentialERC20` example contract on Sepolia. You could then use this other command to mint some amount of confidential tokens:
```
pnpm mint-sepolia
```

### Etherscan verification

If you are using a real instance of the fhEVM, you can verify your deployed contracts on the Etherscan explorer.
You first need to set the `ETHERSCAN_API_KEY` variable in the `.env` file to a valid value. You can get such an API key for free by creating an account on the [Etherscan website](https://docs.etherscan.io/getting-started/viewing-api-usage-statistics).

Then, simply use the `verify-deployed` hardhat task, via this command:
```
npx hardhat verify-deployed --address [ADDRESS_CONTRACT_TO_VERIFY] --contract [FULL_CONTRACT_PATH] --args "[CONSTRUCTOR_ARGUMENTS_COMMA_SEPARATED]" --network [NETWORK_NAME]
```
As a concrete example, to verify the deployed `MyConfidentialERC20` from previous section, you can use:
```
npx hardhat verify-deployed --address [CONFIDENTIAL_ERC20_ADDRESS] --contract contracts/MyConfidentialERC20.sol:MyConfidentialERC20 --args "Naraggara,NARA" --network sepolia
```

Note that you should replace the address placeholder `[CONFIDENTIAL_ERC20_ADDRESS]` by the concrete address that is logged when you run the `pnpm deploy-sepolia` deployment script.

### Syntax Highlighting

If you use VSCode, you can get Solidity syntax highlighting with the
[hardhat-solidity](https://marketplace.visualstudio.com/items?itemName=NomicFoundation.hardhat-solidity) extension.

## License

This project is licensed under MIT.
