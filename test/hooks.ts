import hre from "hardhat";

import { setCodeMocked } from "./mockedSetup";

export const mochaHooks = {
  async beforeAll() {
    // do something before every test
    if (hre.network.name === "hardhat") {
      await setCodeMocked(hre);
    }
  },
};
