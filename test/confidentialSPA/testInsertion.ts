import { expect } from "chai";
import { parseEther } from "ethers";
import { FhevmInstance } from "fhevmjs/node";
import { ethers } from "hardhat";

import { ConfidentialSPA } from "../../types";
import { awaitAllDecryptionResults, initGateway } from "../asyncDecrypt";
import { createInstance } from "../instance";
import { Signers, getSigners, initSigners } from "../signers";

describe("Confidential FenwickTree", () => {
  let signers: Signers;
  let contract: ConfidentialSPA;
  let contractAddress: string;
  let fhevm: FhevmInstance;

  before(async function () {
    await initSigners();
    signers = await getSigners();
    await initGateway();
  });

  beforeEach(async function () {
    const contractFactory = await ethers.getContractFactory("ConfidentialSPA");
    contract = await contractFactory.connect(signers.alice).deploy(1_000_000, 9999999999999999n);
    await contract.waitForDeployment();
    contractAddress = await contract.getAddress();
    fhevm = await createInstance();
  });

  async function addBid(price: number | bigint, amount: number | bigint) {
    const input = fhevm.createEncryptedInput(contractAddress, signers.alice.address);
    input.add128(amount);

    const encryptedInput = await input.encrypt();
    return await contract.connect(signers.alice).addBid(price, encryptedInput.handles[0], encryptedInput.inputProof);
  }

  async function computeClearancePrice() {
    await (await contract.startComputeClearancePrice()).wait();

    let i = 0;
    while (await contract.isRunningComputeClearancePrice()) {
      (await contract.stepComputeClearancePrice()).wait();
      await awaitAllDecryptionResults();
      i++;
    }

    expect(i).to.be.equal(8);
  }

  it("should add bids with encrypted amount", async () => {
    await (await addBid(parseEther("0.000002"), 500_000)).wait();
    await (await addBid(parseEther("0.000008"), 600_000)).wait();
    await (await addBid(parseEther("0.000000001"), 1_000_000)).wait();

    await computeClearancePrice();

    expect(await contract.clearancePrice()).to.equal(await contract.priceToUint8(parseEther("0.000002")));
  });
});
