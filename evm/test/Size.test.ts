import { expect } from "chai";
import hre from "hardhat";

/** EIP-170. The test network lifts it for the mocks, so it is checked here. */
const MAX_CODE_SIZE = 24_576;

describe("Size", () => {
  for (const name of ["UtxoChain", "UtxoChainToken"]) {
    it(`should keep ${name} under the contract size limit`, async () => {
      const artifact = await hre.artifacts.readArtifact(name);

      expect((artifact.deployedBytecode.length - 2) / 2).to.be.at.most(MAX_CODE_SIZE);
    });
  }
});
