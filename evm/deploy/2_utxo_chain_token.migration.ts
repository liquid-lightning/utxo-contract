import type { ContractRunner } from "ethers";

import type { Deployer } from "@solarity/hardhat-migrate";
import { Reporter } from "@solarity/hardhat-migrate";

import { IERC20__factory, UtxoChainToken__factory } from "@ethers-v6";

import { getConfig } from "./config/index.js";

/** 10^(decimals - 8), or 1 below 8 decimals (SPEC 4.6). */
function unitsPerSat(decimals: bigint): bigint {
  return decimals > 8n ? 10n ** (decimals - 8n) : 1n;
}

export default async function (deployer: Deployer) {
  const config = getConfig(await deployer.getChainId());
  // (hardhat-migrate carries its own copy of ethers, so its signer's type differs.)
  const signer = (await deployer.getSigner()) as unknown as ContractRunner;
  const deployed: [string, string][] = [];

  for (const token of config.tokens) {
    const decimals = await IERC20__factory.connect(token, signer).decimals();

    const chain = await deployer.deploy(UtxoChainToken__factory, [config.interval, token, unitsPerSat(decimals)], {
      name: `UtxoChainToken ${token}`,
    });

    deployed.push([`UtxoChainToken ${token}`, await chain.getAddress()]);
  }

  if (deployed.length != 0) {
    Reporter.reportContracts(...deployed);
  }
}
