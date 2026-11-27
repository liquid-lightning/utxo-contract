import hardhatToolboxMochaEthers from "@nomicfoundation/hardhat-toolbox-mocha-ethers";

import hardhatMigrate from "@solarity/hardhat-migrate";

import { configVariable, defineConfig } from "hardhat/config";

import hardhatContractSizer from "@solidstate/hardhat-contract-sizer";

// A local solc binary, for machines that can't download the compiler.
const solcPath = process.env.SOLC_PATH ? { path: process.env.SOLC_PATH } : {};

export default defineConfig({
  plugins: [hardhatToolboxMochaEthers, hardhatMigrate, hardhatContractSizer],
  paths: {
    sources: {
      solidity: ["contracts"],
    },
  },
  solidity: {
    version: "0.8.30",
    ...solcPath,
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      // Osaka (Fusaka): EIP-7883 modexp pricing, which the key recovery pays for.
      evmVersion: "osaka",
    },
    npmFilesToBuild: [],
  },
  networks: {
    default: {
      type: "edr-simulated",
      chainType: "l1",
      hardfork: "osaka",
      initialDate: "2023-11-14T22:00:00Z",
      // The mocks add test-only functions on top of contracts that sit just
      // under the limit; test/Size.test.ts checks the deployable ones.
      allowUnlimitedContractSize: true,
    },
    // The same, on Base Sepolia's chain id: the reference's deposit cases
    // commit to it (test/v1/Reference.test.ts).
    simulatedBaseSepolia: {
      type: "edr-simulated",
      chainType: "l1",
      chainId: 84532,
      hardfork: "osaka",
      initialDate: "2023-11-14T22:00:00Z",
      allowUnlimitedContractSize: true,
    },
    localhost: {
      type: "http",
      chainType: "l1",
      url: "http://127.0.0.1:8545",
      gasMultiplier: 1.2,
    },
    baseSepolia: {
      type: "http",
      chainType: "op",
      url: configVariable("BASE_SEPOLIA_RPC_URL"),
      accounts: [configVariable("PRIVATE_KEY")],
      gasMultiplier: 1.2,
    },
  },
  verify: {
    blockscout: {
      enabled: false,
    },
    etherscan: {
      apiKey: configVariable("ETHERSCAN_KEY"),
    },
    sourcify: {
      enabled: false,
    },
  },
  migrate: {
    paths: {
      pathToMigrations: "./deploy/",
    },
  },
  test: {
    mocha: {
      timeout: 1_000_000,
    },
  },
  contractSizer: {
    alphaSort: false,
    runOnCompile: true,
    flat: true,
    strict: false,
    unit: "B",
  },
  typechain: {
    outDir: "generated-types/ethers",
    alwaysGenerateOverloads: false,
    dontOverrideCompile: false,
    discriminateTypes: true,
    tsNocheck: false,
  },
});
