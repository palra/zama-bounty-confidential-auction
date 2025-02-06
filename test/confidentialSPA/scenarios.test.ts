import { time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { use as chaiUse, expect } from "chai";
import chaiAsPromised from "chai-as-promised";
import { Signer, parseUnits } from "ethers";
import { FhevmInstance } from "fhevmjs/node";
import { ethers } from "hardhat";

import { ConfidentialSPA, MockConfidentialERC20 } from "../../types";
import { awaitAllDecryptionResults, initGateway } from "../asyncDecrypt";
import { createInstance } from "../instance";
import { reencryptEuint8 } from "../reencrypt";
import { Signers, getSigners, initSigners } from "../signers";
import { debug } from "../utils";

chaiUse(chaiAsPromised);

const parsePrice = (val: string | number) => parseUnits(val.toString().replace(/[\s_]/g, ""), 12);
const parseAmount = (val: string | number) => parseUnits(val.toString(), 6);

enum ErrorCode {
  NO_ERROR = 0,
  TRANSFER_FAILED = 1,
  VALIDATION_ERROR = 2,
}

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

  async function balanceOf(address: string, token: MockConfidentialERC20) {
    const handle = await token.balanceOf(address);
    if (handle === 0n) return 0;
    return await debug.decrypt64(handle);
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
    await awaitAllDecryptionResults();
    expect(await balanceOf(signers.alice.address, tokenAuction)).to.equal(0n);

    await time.increase(BID_DURATION);

    await withdrawalDecrypt();
    expect(await contract.auctionState()).to.equal(2); // 2 = Cancelled
    await (await contract.recoverAuctioneer()).wait();
    expect(await balanceOf(signers.alice.address, tokenAuction)).to.equal(1_000_000n);
  });

  it("should refund bidders if the owner cancels the auction", async () => {
    await contract.connect(signers.alice).depositAuction();
    await awaitAllDecryptionResults();
    expect(await balanceOf(signers.alice.address, tokenAuction)).to.equal(0n);
    expect(await balanceOf(contractAddress, tokenAuction)).to.equal(1_000_000n);

    for (const [signer, price, quantity, baseBalance, contractBalance] of [
      [signers.bob, "0.000002", 500_000, 1_000_000_000n - parseAmount(1), parseAmount(1)],
      [signers.bob, "0.000005", 0, 1_000_000_000n - parseAmount(1), parseAmount(1)],
      [signers.carol, "0.000001", 0, 1_000_000_000n, parseAmount(1)],
      [signers.carol, "0.000008", 600_000, 1_000_000_000n - parseAmount("4.8"), parseAmount("5.8")],
      [signers.dave, "0.000000001", 0, 1_000_000_000n, parseAmount("5.8")],
    ] as const) {
      await (await bid(parsePrice(price), quantity, signer)).wait();
      expect(await balanceOf(signer.address, tokenBase)).to.equal(baseBalance);
      expect(await balanceOf(contractAddress, tokenBase)).to.equal(contractBalance);
    }

    await time.increase(BID_DURATION / 2); // Not yet finished, so it can still be cancelled.

    await (await contract.connect(signers.alice).cancel()).wait();

    expect(await contract.auctionState()).to.equal(2); // 2 = Cancelled

    await (await contract.recoverAuctioneer()).wait();

    expect(await balanceOf(signers.alice.address, tokenAuction)).to.equal(1_000_000n);

    for (const signer of [signers.bob, signers.carol, signers.dave]) {
      await (await contract.recoverBidder(signer.address)).wait();
      expect(await balanceOf(signer.address, tokenBase)).to.equal(1_000_000_000n);
    }
  });

  it("should work with the bounty example", async () => {
    await contract.connect(signers.alice).depositAuction();
    await awaitAllDecryptionResults();
    expect(await balanceOf(signers.alice.address, tokenAuction)).to.equal(0n);

    await (await bid(parsePrice("0.000002"), 500_000, signers.bob)).wait();
    expect(await contract.tickToPrice(await contract.priceToTick(parsePrice("0.000002")))).to.equal(
      parsePrice("0.000002"),
    );
    expect(await balanceOf(signers.bob.address, tokenBase)).to.equal(1_000_000_000n - parseAmount(1));

    await (await bid(parsePrice("0.000008"), 600_000, signers.carol)).wait();
    expect(await contract.tickToPrice(await contract.priceToTick(parsePrice("0.000008")))).to.equal(
      parsePrice("0.000008"),
    );
    expect(await balanceOf(signers.carol.address, tokenBase)).to.equal(1_000_000_000n - parseAmount("4.8"));

    await (await bid(parsePrice("0.00000000001"), 1_000_000, signers.dave)).wait();
    expect(await contract.tickToPrice(await contract.priceToTick(parsePrice("0.00000000001")))).to.equal(153n);
    expect(await balanceOf(signers.dave.address, tokenBase)).to.equal(1_000_000_000n - parseAmount("0.000153"));

    await time.increase(BID_DURATION);

    await withdrawalDecrypt();

    expect(await contract.settlementPriceTick()).to.equal(await contract.priceToTick(parsePrice("0.000002")));

    await (await contract.connect(signers.alice).pullAuctioneer()).wait();
    for (const signer of [signers.bob, signers.carol, signers.dave]) {
      await (await contract.connect(signer).popBid(signer.address)).wait();
    }

    expect(await balanceOf(contractAddress, tokenAuction)).to.equal(0n);
    expect(await balanceOf(contractAddress, tokenBase)).to.equal(0n);

    for (const [signer, auctionAmt, baseAmt] of [
      [signers.alice, 0, 1_000_000_000n + parseAmount(2)],
      [signers.bob, 400_000n, 1_000_000_000n - parseAmount("0.8")],
      [signers.carol, 600_000n, 1_000_000_000n - parseAmount("1.2")],
      [signers.dave, 0n, 1_000_000_000n],
    ] as const) {
      expect(await balanceOf(signer.address, tokenAuction)).to.equal(auctionAmt);
      expect(await balanceOf(signer.address, tokenBase)).to.equal(baseAmt);
    }
  });

  describe("multiple bids at the same price", () => {
    it("should resolve - greater than the settlement price", async () => {
      await contract.connect(signers.alice).depositAuction();
      await awaitAllDecryptionResults();

      await (await bid(parsePrice("0.000008"), 400_000, signers.bob)).wait();
      await (await bid(parsePrice("0.000008"), 400_000, signers.carol)).wait();
      await (await bid(parsePrice("0.000002"), 200_000, signers.dave)).wait();

      await time.increase(BID_DURATION);

      await withdrawalDecrypt();

      expect(await contract.settlementPriceTick()).to.equal(await contract.priceToTick(parsePrice("0.000002")));

      await (await contract.connect(signers.alice).pullAuctioneer()).wait();
      for (const signer of [signers.bob, signers.carol, signers.dave]) {
        await (await contract.connect(signer).popBid(signer.address)).wait();
      }

      expect(await balanceOf(contractAddress, tokenAuction)).to.equal(0n);
      expect(await balanceOf(contractAddress, tokenBase)).to.equal(0n);

      for (const [signer, auctionAmt, baseAmt] of [
        [signers.alice, 0, 1_000_000_000n + parseAmount(2)],
        [signers.bob, 400_000n, 1_000_000_000n - parseAmount("0.8")],
        [signers.carol, 400_000n, 1_000_000_000n - parseAmount("0.8")],
        [signers.dave, 200_000n, 1_000_000_000n - parseAmount("0.4")],
      ] as const) {
        expect(await balanceOf(signer.address, tokenAuction)).to.equal(auctionAmt);
        expect(await balanceOf(signer.address, tokenBase)).to.equal(baseAmt);
      }
    });

    it("should resolve - at the settlement price, compete for first", async () => {
      await contract.connect(signers.alice).depositAuction();
      await awaitAllDecryptionResults();

      await (await bid(parsePrice("0.000002"), 400_000, signers.bob)).wait();
      await (await bid(parsePrice("0.000002"), 500_000, signers.carol)).wait();
      await (await bid(parsePrice("0.000002"), 800_000, signers.dave)).wait();

      await time.increase(BID_DURATION);

      await withdrawalDecrypt();

      expect(await contract.settlementPriceTick()).to.equal(await contract.priceToTick(parsePrice("0.000002")));

      await (await contract.connect(signers.alice).pullAuctioneer()).wait();

      // order matters
      for (const signer of [signers.carol, signers.dave, signers.bob]) {
        await (await contract.connect(signer).popBid(signer.address)).wait();
      }

      expect(await balanceOf(contractAddress, tokenAuction)).to.equal(0n);
      expect(await balanceOf(contractAddress, tokenBase)).to.equal(0n);

      for (const [signer, auctionAmt, baseAmt] of [
        [signers.alice, 0, 1_000_000_000n + parseAmount(2)],
        [signers.carol, 500_000n, 1_000_000_000n - parseAmount(1)],
        [signers.dave, 500_000n, 1_000_000_000n - parseAmount(1)],
        [signers.bob, 0, 1_000_000_000n],
      ] as const) {
        expect(await balanceOf(signer.address, tokenAuction)).to.equal(auctionAmt);
        expect(await balanceOf(signer.address, tokenBase)).to.equal(baseAmt);
      }
    });

    it("should resolve - rejected offers", async () => {
      await contract.connect(signers.alice).depositAuction();
      await awaitAllDecryptionResults();

      await (await bid(parsePrice("0.000002"), 1_000_000, signers.bob)).wait();
      await (await bid(parsePrice("0.000001"), 500_000, signers.carol)).wait();
      await (await bid(parsePrice("0.000001"), 800_000, signers.dave)).wait();
      await (await bid(parsePrice("0.00000005"), 1_000_000, signers.eve)).wait();

      await time.increase(BID_DURATION);

      await withdrawalDecrypt();

      expect(await contract.settlementPriceTick()).to.equal(await contract.priceToTick(parsePrice("0.000002")));

      await (await contract.connect(signers.alice).pullAuctioneer()).wait();

      for (const signer of [signers.bob, signers.carol, signers.dave, signers.eve]) {
        await (await contract.connect(signer).popBid(signer.address)).wait();
      }

      expect(await balanceOf(contractAddress, tokenAuction)).to.equal(0n);
      expect(await balanceOf(contractAddress, tokenBase)).to.equal(0n);

      for (const [signer, auctionAmt, baseAmt] of [
        [signers.alice, 0, 1_000_000_000n + parseAmount(2)],
        [signers.bob, 1_000_000n, 1_000_000_000n - parseAmount(2)],
        [signers.carol, 0, 1_000_000_000n],
        [signers.dave, 0, 1_000_000_000n],
        [signers.eve, 0, 1_000_000_000n],
      ] as const) {
        expect(await balanceOf(signer.address, tokenAuction)).to.equal(auctionAmt);
        expect(await balanceOf(signer.address, tokenBase)).to.equal(baseAmt);
      }
    });
  });

  describe("error handling", () => {
    it("should not revert and signal an encrypted error when the quantity exceeds the auction amount", async () => {
      await contract.connect(signers.alice).depositAuction();
      await awaitAllDecryptionResults();

      {
        const tx = await bid(parsePrice("0.000002"), 2_000_000, signers.bob);
        await expect(tx).to.not.be.reverted;
        await expect(tx).to.emit(contract, "ErrorChanged").withArgs(signers.bob.address, 1);
      }
      expect(await balanceOf(contractAddress, tokenBase)).to.be.equal(0n);
      expect(await balanceOf(signers.bob.address, tokenBase)).to.be.equal(1_000_000_000n);

      const [eErrorCode] = await contract.connect(signers.bob).getLastEncryptedError();
      await expect(reencryptEuint8(signers.bob, fhevm, eErrorCode, contractAddress)).to.eventually.be.equal(
        ErrorCode.VALIDATION_ERROR,
      );

      // Check correct encryption: should not be decrypted by others
      await expect(reencryptEuint8(signers.alice, fhevm, eErrorCode, contractAddress)).to.be.rejected;

      await time.increase(BID_DURATION);
      await withdrawalDecrypt();
      expect(await contract.auctionState()).to.be.equal(2); // 2 = Cancelled, no valid bid

      await (await contract.connect(signers.alice).recoverAuctioneer()).wait();
      expect(await balanceOf(signers.alice.address, tokenAuction)).to.be.equal(1_000_000n);
      expect(await balanceOf(signers.alice.address, tokenBase)).to.be.equal(1_000_000_000n);

      await (await contract.connect(signers.bob).recoverBidder(signers.bob.address)).wait();
      expect(await balanceOf(signers.bob.address, tokenAuction)).to.be.equal(0n);
      expect(await balanceOf(signers.bob.address, tokenBase)).to.be.equal(1_000_000_000n);
    });
    it("should not revert and signal a transfer error if bidder's allowance is insufficient", async () => {
      await contract.connect(signers.alice).depositAuction();
      await awaitAllDecryptionResults();

      {
        // Reset allowance to trigger the error
        const input = fhevm.createEncryptedInput(await tokenBase.getAddress(), signers.bob.address);
        input.add64(0);
        const {
          handles: [allowance],
          inputProof,
        } = await input.encrypt();
        await tokenBase.connect(signers.bob)["approve(address,bytes32,bytes)"](contractAddress, allowance, inputProof);

        const tx = await bid(parsePrice("0.000002"), 500_000, signers.bob);
        await expect(tx).to.not.be.reverted;
        await expect(tx).to.emit(contract, "ErrorChanged").withArgs(signers.bob.address, 1);
      }
      expect(await balanceOf(contractAddress, tokenBase)).to.be.equal(0n); // No tokens transferred
      expect(await balanceOf(signers.bob.address, tokenBase)).to.be.equal(1_000_000_000n); // No tokens debited

      const [eErrorCode] = await contract.connect(signers.bob).getLastEncryptedError();
      await expect(reencryptEuint8(signers.bob, fhevm, eErrorCode, contractAddress)).to.eventually.be.equal(
        ErrorCode.TRANSFER_FAILED,
      );

      await time.increase(BID_DURATION);
      await withdrawalDecrypt();
      expect(await contract.auctionState()).to.be.equal(2); // 2 = Cancelled, no valid bid

      await (await contract.connect(signers.alice).recoverAuctioneer()).wait();
      expect(await balanceOf(signers.alice.address, tokenAuction)).to.be.equal(1_000_000n);
      expect(await balanceOf(signers.alice.address, tokenBase)).to.be.equal(1_000_000_000n);

      await (await contract.connect(signers.bob).recoverBidder(signers.bob.address)).wait();
      expect(await balanceOf(signers.bob.address, tokenAuction)).to.be.equal(0n);
      expect(await balanceOf(signers.bob.address, tokenBase)).to.be.equal(1_000_000_000n);
    });

    it("should not switch to active state if the auctioneer deposit failed", async () => {
      // Reset allowance to trigger the error
      {
        const input = fhevm.createEncryptedInput(await tokenAuction.getAddress(), signers.alice.address);
        input.add64(0);
        const {
          handles: [allowance],
          inputProof,
        } = await input.encrypt();
        await tokenAuction
          .connect(signers.alice)
          ["approve(address,bytes32,bytes)"](contractAddress, allowance, inputProof);
      }

      {
        const tx = await contract.connect(signers.alice).depositAuction();
        await expect(tx).to.emit(contract, "ErrorChanged").withArgs(signers.alice.address, 0);
      }
      expect(await contract.auctionState()).to.be.equal(0); // 0 = WaitDeposit
      {
        const eErrorCode = await contract.connect(signers.alice).getEncryptedErrorIndex(0);
        expect(await reencryptEuint8(signers.alice, fhevm, eErrorCode, contractAddress)).to.be.equal(
          ErrorCode.TRANSFER_FAILED,
        );
      }

      await awaitAllDecryptionResults();
      expect(await contract.auctionState()).to.be.equal(0); // 0 = WaitDeposit

      // Set correct allowance
      {
        const input = fhevm.createEncryptedInput(await tokenAuction.getAddress(), signers.alice.address);
        input.add64(1_000_000);
        const {
          handles: [allowance],
          inputProof,
        } = await input.encrypt();
        await tokenAuction
          .connect(signers.alice)
          ["approve(address,bytes32,bytes)"](contractAddress, allowance, inputProof);
      }

      {
        const tx = await contract.connect(signers.alice).depositAuction();
        await expect(tx).to.emit(contract, "ErrorChanged").withArgs(signers.alice.address, 1);
      }
      expect(await contract.auctionState()).to.be.equal(0); // 0 = WaitDeposit
      {
        const eErrorCode = await contract.connect(signers.alice).getEncryptedErrorIndex(1);
        expect(await reencryptEuint8(signers.alice, fhevm, eErrorCode, contractAddress)).to.be.equal(
          ErrorCode.NO_ERROR,
        );
      }

      await awaitAllDecryptionResults();
      expect(await contract.auctionState()).to.be.equal(1); // 1 = Active
    });

    it("should emit only one error per individual action", async () => {
      await expect(contract.connect(signers.alice).depositAuction())
        .to.emit(contract, "ErrorChanged")
        .withArgs(signers.alice.address, 0);
      await expect(contract.getEncryptedErrorIndex(1)).to.be.rejected;
    });
  });

  describe("access control", () => {
    it("should allow deposit only for auctioneer", async () => {
      await expect(contract.connect(signers.bob).depositAuction()).to.be.revertedWithCustomError(
        contract,
        "OwnableUnauthorizedAccount",
      );
    });
    it("should allow cancellation only for auctioneer", async () => {
      await contract.connect(signers.alice).depositAuction();
      await awaitAllDecryptionResults();

      await expect(contract.connect(signers.bob).cancel()).to.be.revertedWithCustomError(
        contract,
        "OwnableUnauthorizedAccount",
      );
    });
    it("should restrict decryption callbacks to the gateway", async () => {
      await expect(contract.connect(signers.alice).callbackDepositAuction(0, true)).to.be.revertedWithoutReason;

      await contract.connect(signers.alice).depositAuction();
      await awaitAllDecryptionResults();

      await bid(parsePrice("0.000_002"), 500_000, signers.bob);
      await bid(parsePrice("0.000_002"), 500_000, signers.carol);
      await bid(parsePrice("0.000_001"), 100_000, signers.carol);

      await time.increase(BID_DURATION);

      await expect(contract.callbackWithdrawalDecryptionStep(0, 1)).to.be.revertedWithoutReason;
      await expect(contract.callbackWithdrawalDecryptionFinal(1, 65535)).to.be.revertedWithoutReason;
    });
    context("when cancelled", () => {
      it("should recover funds only once per actor", async () => {
        await contract.connect(signers.alice).depositAuction();
        await awaitAllDecryptionResults();

        await bid(parsePrice("0.000_002"), 500_000, signers.bob);
        await bid(parsePrice("0.000_002"), 500_000, signers.carol);
        await bid(parsePrice("0.000_001"), 100_000, signers.carol);

        await contract.connect(signers.alice).cancel();

        await expect(contract.connect(signers.alice).recoverAuctioneer()).not.to.be.reverted;
        await expect(contract.connect(signers.alice).recoverAuctioneer()).to.be.reverted;
        expect(await balanceOf(signers.alice.address, tokenAuction)).to.equal(1_000_000);

        for (const bidder of [signers.bob, signers.carol, signers.dave]) {
          await expect(contract.connect(bidder).recoverBidder(bidder.address)).not.to.be.reverted;
          await expect(contract.connect(bidder).recoverBidder(bidder.address)).to.be.reverted;
          await expect(contract.connect(signers.alice).recoverBidder(signers.bob.address)).to.be.reverted;
          expect(await balanceOf(bidder.address, tokenAuction)).to.equal(0);
          expect(await balanceOf(bidder.address, tokenBase)).to.equal(1_000_000_000);
        }
      });
    });
    context("when withdrawal ready", () => {
      it("should pull funds only once per actor", async () => {
        await contract.connect(signers.alice).depositAuction();
        await awaitAllDecryptionResults();

        await bid(parsePrice("0.000_002"), 500_000, signers.bob);
        await bid(parsePrice("0.000_002"), 500_000, signers.carol);
        await bid(parsePrice("0.000_001"), 100_000, signers.dave);

        await time.increase(BID_DURATION);
        await withdrawalDecrypt();

        await expect(contract.connect(signers.alice).pullAuctioneer()).not.to.be.reverted;
        await expect(contract.connect(signers.alice).pullAuctioneer()).to.be.reverted;
        expect(await balanceOf(signers.alice.address, tokenAuction)).to.equal(0);
        expect(await balanceOf(signers.alice.address, tokenBase)).to.equal(1_000_000_000n + parseAmount(2));

        for (const bidder of [signers.bob, signers.carol, signers.dave]) {
          await expect(contract.connect(bidder).pullBid(bidder.address, 0)).not.to.be.reverted;
          await expect(contract.connect(bidder).pullBid(bidder.address, 0)).to.be.reverted;
          await expect(contract.connect(signers.alice).pullBid(signers.bob.address, 0)).to.be.reverted;
        }
        expect(await balanceOf(contractAddress, tokenAuction)).to.equal(0);
        expect(await balanceOf(contractAddress, tokenBase)).to.equal(0);
      });
    });
  });
});
