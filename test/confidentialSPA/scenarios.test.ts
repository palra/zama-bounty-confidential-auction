import { time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { Signer, parseUnits } from "ethers";
import { FhevmInstance } from "fhevmjs/node";
import { ethers } from "hardhat";
import { parse } from "path";

import { ConfidentialSPA, MockConfidentialERC20 } from "../../types";
import { awaitAllDecryptionResults, initGateway } from "../asyncDecrypt";
import { createInstance } from "../instance";
import { Signers, getSigners, initSigners } from "../signers";
import { debug } from "../utils";

const parsePrice = (val: string | number) => parseUnits(val.toString(), 12);
const parseAmount = (val: string | number) => parseUnits(val.toString(), 6);

describe("Confidential FenwickTree", () => {
  let signers: Signers;
  let contract: ConfidentialSPA;
  let tokenAuction: MockConfidentialERC20;
  let tokenBase: MockConfidentialERC20;
  let contractAddress: string;
  let fhevm: FhevmInstance;

  const BID_DURATION = 10 * 60;

  before(async function () {
    await initSigners();
    signers = await getSigners();
    await initGateway();
  });

  beforeEach(async function () {
    const erc20Factory = await ethers.getContractFactory("MockConfidentialERC20");
    tokenAuction = await erc20Factory.connect(signers.alice).deploy("ToAuction", "TA");
    tokenBase = await erc20Factory.connect(signers.alice).deploy("Wrapped ETH", "WETH");

    await tokenAuction.connect(signers.alice).mint(signers.alice.address, 1_000_000);

    for (const signer of Object.values(signers)) {
      await tokenBase.connect(signers.alice).mint(signer.address, 1_000_000_000);
    }

    const contractFactory = await ethers.getContractFactory("ConfidentialSPA");
    contract = await contractFactory
      .connect(signers.alice)
      .deploy(
        signers.alice.address,
        tokenAuction.getAddress(),
        1_000_000,
        tokenBase.getAddress(),
        (await time.latest()) + BID_DURATION,
        0n,
        10n ** 7n,
      );

    await contract.waitForDeployment();
    contractAddress = await contract.getAddress();
    fhevm = await createInstance();

    for (const signer of Object.values(signers)) {
      for (const [token, allowance] of [
        [tokenAuction, 1_000_000],
        [tokenBase, 1_000_000_000],
      ] as const) {
        const input = fhevm.createEncryptedInput(await token.getAddress(), signer.address);
        input.add64(allowance);
        const encryptedInput = await input.encrypt();

        await token.connect(signer)[
          // eslint-disable-next-line no-unexpected-multiline
          "approve(address,bytes32,bytes)"
        ](contractAddress, encryptedInput.handles[0], encryptedInput.inputProof);
      }
    }
  });

  async function bid(price: number | bigint, amount: number | bigint, signer: Signer) {
    const input = fhevm.createEncryptedInput(contractAddress, await signer.getAddress());
    input.add64(amount);

    const encryptedInput = await input.encrypt();
    return await contract.connect(signer).bid(price, encryptedInput.handles[0], encryptedInput.inputProof);
  }

  async function withdrawalDecrypt() {
    await (await contract.startWithdrawalDecryption()).wait();

    if ((await contract.auctionState()) === 2n) {
      return;
    }

    while (await contract.isRunningWithdrawalDecryption()) {
      (await contract.stepWithdrawalDecryption()).wait();
      await awaitAllDecryptionResults();
    }
  }

  it("should refund the auctioneer if there is no bid", async () => {
    await contract.connect(signers.alice).depositAuction();
    expect(await debug.decrypt64(await tokenAuction.balanceOf(signers.alice))).to.equal(0n);

    await time.increase(BID_DURATION);

    await withdrawalDecrypt();
    expect(await contract.auctionState()).to.equal(2); // 2 = Cancelled
    await (await contract.recoverAuctioneer()).wait();
    expect(await debug.decrypt64(await tokenAuction.balanceOf(signers.alice))).to.equal(1_000_000n);
  });

  it("should refund bidders if the owner cancels the auction", async () => {
    await contract.connect(signers.alice).depositAuction();
    expect(await debug.decrypt64(await tokenAuction.balanceOf(signers.alice))).to.equal(0n);

    for (const [signer, price, quantity, baseBalance] of [
      [signers.bob, "0.000002", 500_000, 1_000_000_000n - parseAmount(1)],
      [signers.bob, "0.000005", 0, 1_000_000_000n - parseAmount(1)],
      [signers.carol, "0.000008", 600_000, 1_000_000_000n - parseAmount("4.8")],
      [signers.dave, "0.000000001", 0, 1_000_000_000n],
    ] as const) {
      await (await bid(parsePrice(price), quantity, signer)).wait();
      expect(await debug.decrypt64(await tokenBase.balanceOf(signer))).to.equal(baseBalance);
    }

    await time.increase(BID_DURATION / 2); // Not yet finished, so it can still be cancelled.

    await (await contract.connect(signers.alice).cancel()).wait();

    expect(await contract.auctionState()).to.equal(2); // 2 = Cancelled

    await (await contract.recoverAuctioneer()).wait();
    expect(await debug.decrypt64(await tokenAuction.balanceOf(signers.alice))).to.equal(1_000_000n);

    for (const signer of [signers.bob, signers.carol, signers.dave]) {
      await (await contract.recoverBidder(signer.address)).wait();
      expect(await debug.decrypt64(await tokenBase.balanceOf(signer))).to.equal(1_000_000_000n);
    }
  });

  it("should work with the bounty example", async () => {
    await contract.connect(signers.alice).depositAuction();
    expect(await debug.decrypt64(await tokenAuction.balanceOf(signers.alice))).to.equal(0n);

    await (await bid(parsePrice("0.000002"), 500_000, signers.bob)).wait();
    expect(await contract.tickToPrice(await contract.priceToTick(parsePrice("0.000002")))).to.equal(
      parsePrice("0.000002"),
    );
    expect(await debug.decrypt64(await tokenBase.balanceOf(signers.bob))).to.equal(1_000_000_000n - parseAmount(1));

    await (await bid(parsePrice("0.000008"), 600_000, signers.carol)).wait();
    expect(await contract.tickToPrice(await contract.priceToTick(parsePrice("0.000008")))).to.equal(
      parsePrice("0.000008"),
    );
    expect(await debug.decrypt64(await tokenBase.balanceOf(signers.carol))).to.equal(
      1_000_000_000n - parseAmount("4.8"),
    );

    await (await bid(parsePrice("0.00000000001"), 1_000_000, signers.dave)).wait();
    expect(await contract.tickToPrice(await contract.priceToTick(parsePrice("0.00000000001")))).to.equal(39216n);
    expect(await debug.decrypt64(await tokenBase.balanceOf(signers.dave))).to.equal(
      1_000_000_000n - parseAmount("0.039216"),
    );

    await time.increase(BID_DURATION);

    await withdrawalDecrypt();

    expect(await contract.clearingPriceTick()).to.equal(await contract.priceToTick(parsePrice("0.000002")));

    await (await contract.connect(signers.alice).pullAuctioneer()).wait();
    for (const signer of [signers.bob, signers.carol, signers.dave]) {
      await (await contract.connect(signer).popBid(signer.address)).wait();
    }

    for (const [signer, auctionAmt, baseAmt] of [
      [signers.alice, 0, 1_000_000_000n + parseAmount(2)],
      [signers.bob, 400_000n, 1_000_000_000n - parseAmount("0.8")],
      [signers.carol, 600_000n, 1_000_000_000n - parseAmount("1.2")],
      [signers.dave, 0n, 1_000_000_000n],
    ] as const) {
      expect(await debug.decrypt64(await tokenAuction.balanceOf(signer))).to.equal(auctionAmt);
      expect(await debug.decrypt64(await tokenBase.balanceOf(signer))).to.equal(baseAmt);
    }
  });
});
