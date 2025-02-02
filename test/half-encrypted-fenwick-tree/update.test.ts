import { expect } from "chai";
import { BigNumberish } from "ethers";
import { FhevmInstance } from "fhevmjs/node";
import { ethers } from "hardhat";

import { MockHEFTImpl } from "../../types";
import { TypedContractMethod } from "../../types/common";
import { awaitAllDecryptionResults, initGateway } from "../asyncDecrypt";
// import { getFHEGasFromTxReceipt } from "../coprocessorUtils";
import { createInstance } from "../instance";
import { Signers, getSigners, initSigners } from "../signers";
import { debug } from "../utils";

describe("Half-Confidential FenwickTree", () => {
  let signers: Signers;
  let contract: MockHEFTImpl;
  let contractAddress: string;
  let fhevm: FhevmInstance;

  before(async function () {
    await initSigners();
    signers = await getSigners();
    await initGateway();
  });

  async function _searchKey(
    key: BigNumberish,
    method: TypedContractMethod<[atValue: BigNumberish], [void], "nonpayable">,
  ) {
    // console.group("Search Key:", method.name, key);
    await (await method(key)).wait();
    // const it = await contract.searchIterator();
    // console.log({
    //   idx: it.idx === 0n ? null : await debug.decrypt8(it.idx),
    //   fallbackIdx: await debug.decrypt8(it.fallbackIdx),
    //   rank: await debug.decrypt128(it.rank),
    //   foundIdx: it.foundIdx === 0n ? null : await debug.decrypt8(it.foundIdx),
    //   found: (await contract.isFound()) ? await contract.found() : null,
    // });

    while (await contract.isRunningSearchKey()) {
      (await contract.stepSearchKey()).wait();
      await awaitAllDecryptionResults();

      // const it = await contract.searchIterator();
      // console.log({
      //   idx: it.idx === 0n ? null : await debug.decrypt8(it.idx),
      //   fallbackIdx: await debug.decrypt8(it.fallbackIdx),
      //   rank: await debug.decrypt128(it.rank),
      //   foundIdx: it.foundIdx === 0n ? null : await debug.decrypt8(it.foundIdx),
      //   found: (await contract.isFound()) ? await contract.found() : null,
      // });
    }

    // console.groupEnd();

    return await debug.decrypt16(await contract.searchResult());
  }

  const searchKey = (key: BigNumberish) => _searchKey(key, contract.startSearchKey);
  const searchKeyFallback = (key: BigNumberish) => _searchKey(key, contract.startSearchKeyFallbackNotFound);

  async function query(key: number | bigint) {
    const tx = await contract.queryKey(key);
    // const receipt =
    await tx.wait();

    // console.log("Query: Native Gas:", receipt?.gasUsed);
    // const fheGas = getFHEGasFromTxReceipt(receipt);
    // const fheMaxGas = 10_000_000;
    // console.log("Query: FHE Gas", `${((fheGas / fheMaxGas) * 100).toFixed(2)}%`, fheGas);

    return await debug.decrypt128(await contract.queryResult());
  }

  async function update(key: number | bigint, amount: number | bigint) {
    const input = fhevm.createEncryptedInput(contractAddress, signers.alice.address);
    input.add128(amount);

    const encryptedInput = await input.encrypt();
    return await contract.connect(signers.alice).update(key, encryptedInput.handles[0], encryptedInput.inputProof);
  }

  beforeEach(async function () {
    const contractFactory = await ethers.getContractFactory("MockHEFTImpl");
    contract = await contractFactory.connect(signers.alice).deploy();
    await contract.waitForDeployment();
    contractAddress = await contract.getAddress();
    fhevm = await createInstance();
  });

  it("should have zero cumulative sum when no items are inserted", async () => {
    expect(await debug.decrypt128(await contract.totalValue())).to.equal(0n);

    for (const [key, quantity] of [
      [1, 0],
      [50, 0],
      [100, 0],
      [200, 0],
      [2 ** 8 - 1, 0],
    ]) {
      await (await contract.queryKey(key)).wait();
      expect(await debug.decrypt128(await contract.queryResult())).to.equal(quantity);
    }

    expect(await searchKey(2000)).to.equal(0n);
  });

  it("should insert a single value and have coherent query results", async () => {
    await update(100, 1337);

    expect(await debug.decrypt128(await contract.totalValue())).to.equal(1337);

    // Single-key queries: cumulative quantity at given index

    for (const [key, quantity] of [
      [1, 0],
      [31, 0],
      [50, 0],
      [100, 1337],
      [200, 1337],
      [2 ** 8 - 1, 1337],
    ]) {
      expect(await query(key)).to.equal(quantity);
    }

    // Range queries: first index at which the cumulative qty. is >= than target

    // Fallback to not found.
    for (const [quantity, appearsAtKey] of [
      [2000, 0],
      [1338, 0],
      [1337, 100],
      [1336, 100],
      [500, 100],
      [50, 100],
      [1, 100],
      // 0 value will always be found at this index
      [0, 1],
    ]) {
      expect(await searchKeyFallback(quantity)).to.equal(appearsAtKey);
    }

    // Fallback to the largest index when not found
    for (const [quantity, appearsAtKey] of [
      [2000, 100],
      [1337, 100],
      [1000, 100],
      [999, 100],
      [50, 100],
      [1, 100],
      // 0 value will always be found at this index
      [0, 1],
    ]) {
      expect(await searchKey(quantity)).to.equal(appearsAtKey);
    }
  });

  it("should work with multiple insertions", async () => {
    for (const [key, quantity] of [
      [10, 25],
      [20, 50],
      [100, 10],
      [200, 15],
    ]) {
      await update(key, quantity);
    }

    expect(await debug.decrypt128(await contract.totalValue())).to.equal(100);

    // Single-key queries
    for (const [key, quantity] of [
      [1, 0],
      [9, 0],
      [10, 25],
      [15, 25],
      [20, 75],
      [99, 75],
      [100, 85],
      [199, 85],
      [200, 100],
      [255, 100],
    ]) {
      expect(await query(key)).to.equal(quantity);
    }

    // Range queries: first index at which the cumulative qty. is >= than target

    // Fallback to not found.
    for (const [quantity, appearsAtKey] of [
      [150, 0],
      [101, 0],
      [100, 200],
      [85, 100],
      [75, 20],
      [25, 10],
      [15, 10],
      [1, 10],
      // 0 value will always be found at this index
      [0, 1],
    ]) {
      expect(await searchKeyFallback(quantity)).to.equal(appearsAtKey);
    }
    // Fallback to the largest index when not found
    for (const [quantity, appearsAtKey] of [
      [150, 200],
      [101, 200],
      [100, 200],
      [85, 100],
      [75, 20],
      [25, 10],
      [15, 10],
      [1, 10],
      // 0 value will always be found at this index
      [0, 1],
    ]) {
      expect(await searchKey(quantity)).to.equal(appearsAtKey);
    }
  });
});
