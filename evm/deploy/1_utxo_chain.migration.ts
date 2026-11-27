import type { Deployer } from "@solarity/hardhat-migrate";
import { Reporter } from "@solarity/hardhat-migrate";

import { UtxoChain__factory } from "@ethers-v6";

import { getConfig } from "./config/index.js";

export default async function (deployer: Deployer) {
  const config = getConfig(await deployer.getChainId());

  const chain = await deployer.deploy(UtxoChain__factory, [config.interval]);

  Reporter.reportContracts(["UtxoChain", await chain.getAddress()]);
}
