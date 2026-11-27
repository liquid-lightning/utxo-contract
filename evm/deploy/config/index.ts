/** What a deployment needs, per chain. */
export interface DeployConfig {
  /** Seconds per virtual block. */
  interval: number;
  /** ERC-20 tokens to deploy a UtxoChainToken for (one instance per token). */
  tokens: string[];
}

const CONFIGS: Record<string, DeployConfig> = {
  // hardhat node, anvil
  "31337": { interval: 2, tokens: [] },
  // Base Sepolia
  "84532": { interval: 60, tokens: [] },
};

export function getConfig(chainId: bigint): DeployConfig {
  const config = CONFIGS[chainId.toString()];

  if (config === undefined) {
    throw new Error(`no deploy config for chain id ${chainId}: add it to deploy/config/index.ts`);
  }

  // UTXO_TOKENS=0x...,0x... adds tokens without editing the config.
  const extra = (process.env.UTXO_TOKENS ?? "").split(",").filter((t) => t.length != 0);

  return { ...config, tokens: [...config.tokens, ...extra] };
}
