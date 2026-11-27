import type { ContractRunner } from "ethers";

import type { Deployer } from "@solarity/hardhat-migrate";
import { Reporter } from "@solarity/hardhat-migrate";

import { IERC20__factory, MultiUtxoChain__factory } from "@ethers-v6";

import { getConfig } from "./config/index.js";

/** 10^(decimals - 8), or 1 below 8 decimals. */
function unitsPerSat(decimals: bigint): bigint {
  return decimals > 8n ? 10n ** (decimals - 8n) : 1n;
}

export default async function (deployer: Deployer) {
  const config = getConfig(await deployer.getChainId());
  const signer = await deployer.getSigner();
  const signerAddress = await signer.getAddress();
  const owner = config.owner ?? signerAddress;

  // The deployer registers the tokens, then hands the chain to its owner.
  const chain = await deployer.deploy(MultiUtxoChain__factory, [config.interval, config.feeAsset, signerAddress]);
  const report: [string, string][] = [["MultiUtxoChain", await chain.getAddress()]];

  for (const token of config.multiTokens) {
    // (hardhat-migrate carries its own copy of ethers, so its signer's type differs.)
    const decimals = await IERC20__factory.connect(token, signer as unknown as ContractRunner).decimals();

    await chain.registerToken(token, unitsPerSat(decimals), { customData: { txName: `register ${token}` } });

    report.push([`asset of ${token}`, await chain.assetOf(token)]);
  }

  if (owner != signerAddress) {
    await chain.transferOwnership(owner, { customData: { txName: "transfer ownership" } });
  }

  Reporter.reportContracts(...report);
}
