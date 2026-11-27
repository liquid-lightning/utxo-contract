/** What a deployment needs, per chain. */
export interface DeployConfig {
  /** Seconds per virtual block. */
  interval: number;
  /** ERC-20 tokens to deploy a UtxoChainToken for (one instance per token). */
  tokens: string[];
  /**
   * v2: the asset tag of ETH in MultiUtxoChain, as serialized in a
   * transaction: the fee asset of the Liquid-type network the nodes run with.
   */
  feeAsset: string;
  /** v2: who may register tokens in MultiUtxoChain (default: the deployer). */
  owner?: string;
  /** v2: ERC-20 tokens to register in MultiUtxoChain. */
  multiTokens: string[];
}

/** L-BTC's asset tag on each Liquid-type network of Core Lightning (bitcoin/chainparams.c). */
export const FEE_ASSETS = {
  liquidRegtest: "0x5ce7b963d37f8f2d51cafbba928aaa9e220b8bbc660571499c03628a3851b8ce",
  liquidTestnet: "0x499a818545f6bae39fc03b637f2a4e1e64e590cac1bc3a6f6d71aa4443654c14",
};

const CONFIGS: Record<string, DeployConfig> = {
  // hardhat node, anvil
  "31337": { interval: 2, tokens: [], feeAsset: FEE_ASSETS.liquidRegtest, multiTokens: [] },
  // Base Sepolia
  "84532": { interval: 60, tokens: [], feeAsset: FEE_ASSETS.liquidTestnet, multiTokens: [] },
};

export function getConfig(chainId: bigint): DeployConfig {
  const config = CONFIGS[chainId.toString()];

  if (config === undefined) {
    throw new Error(`no deploy config for chain id ${chainId}: add it to deploy/config/index.ts`);
  }

  // UTXO_TOKENS=0x...,0x... (v1) and MULTI_TOKENS=0x...,0x... (v2) add tokens
  // without editing the config.
  const list = (value: string | undefined) => (value ?? "").split(",").filter((t) => t.length != 0);

  return {
    ...config,
    tokens: [...config.tokens, ...list(process.env.UTXO_TOKENS)],
    multiTokens: [...config.multiTokens, ...list(process.env.MULTI_TOKENS)],
  };
}
