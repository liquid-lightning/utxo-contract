# UtxoChain contract

The contract of `SPEC.md` section 4 (in the
[evm-plugin](https://github.com/liquid-lightning/evm-plugin) repository), as a
Hardhat project laid out the [Solarity](https://github.com/dl-solarity) way.

```
contracts/
  v1/                 AUtxoChain (the logic), UtxoChain (ETH), UtxoChainToken (one ERC-20)
  interfaces/         the NatSpec lives here
  libs/bitcoin/       transaction parser, BIP143 and BIP341 sighashes, script templates, validation
  libs/crypto/        ECDSA and Schnorr on secp256k1
  libs/utils/         every error the contract reverts with
  mock/               test-only contracts
deploy/               hardhat-migrate migrations
test/                 Mocha tests, one file per contract; test/data holds the vectors
```

The two deployables add the asset to `AUtxoChain`:

- `UtxoChain` holds ETH (1 sat = 10^10 wei).
- `UtxoChainToken` holds one ERC-20, one instance per token (SPEC 4.6).
  1 sat = `UNITS_PER_SAT` token units, which is 10^(decimals - 8), or 1 below
  8 decimals. `deposit(amount, script)` pulls with `transferFrom` (approve
  first), and `withdraw()` pays with `transfer`. No-bool tokens (USDT) work.
  A balance check on every token call refuses fee-on-transfer tokens.
  Rebasing tokens MUST NOT be used.

The contracts have no dependencies. They need solc 0.8.30 and the Osaka EVM
(EIP-7883 modexp pricing).

## Build and test

```
npm install
npm run build
npm run test
```

If the machine can't download the compiler, point `SOLC_PATH` at a local
solc 0.8.30 binary.

What the tests cover:

- `test/v1/UtxoChain.test.ts`, `UtxoChainToken.test.ts`: every real Core
  Lightning transaction of the vector files replayed in order, synthetic
  spends for the paths and hash types those lack, 610 tampered transactions
  each failing with its error, deposits byte for byte, exits, fees and
  withdrawals, re-entrancy, and the SPEC 4.1 balance invariant after every
  step. The token suite runs them in token units, for 6 and 18 decimals, and
  adds the tokens the contract must refuse.
- `test/libs`: the official BIP340 and BIP341 vectors.
- `test/v1/Reference.test.ts`: the differential test against the independent
  Python reference (7,648 transactions and 112 deposits). Its cases are large
  and not in git, and the test is skipped without them.
- `test/Size.test.ts`: both deployables fit the 24,576-byte limit. The test
  network lifts the limit, because the mocks add functions to contracts that
  sit just under it.

### Test vectors

`test/data/v1/vectors.json` is generated, deterministically, by the Python
side in the evm-plugin repository, from the real CLN transactions in its
`tests/vectors/*.jsonl`:

```
cd ../../evm-plugin
(cd reference && python3 fuzz.py)        # reference/cases/: the differential cases
python3 -I export_json.py --out ../utxo-contract/evm/test/data/v1 --full
```

`--full` also copies the differential cases to `test/data/v1/full`. Python
needs `coincurve`. Rerun it after the vectors or the reference change.

## Deploying

`deploy/config/index.ts` holds the virtual block interval per chain id (2 s
on a local node, 60 s on Base Sepolia) and the tokens to deploy a
`UtxoChainToken` for. `UTXO_TOKENS=0x...,0x...` adds tokens for one run.

```
npm run private-network          # in another terminal
npm run deploy-localhost

cp .env.example .env             # PRIVATE_KEY, BASE_SEPOLIA_RPC_URL, ETHERSCAN_KEY
npm run deploy-base-sepolia      # deploys and verifies
```

Migration 1 deploys `UtxoChain`; migration 2 deploys one `UtxoChainToken`
per configured token, reading its `decimals()` for the units per sat. A
report of the run is written under `cache/`. `npx hardhat migrate --continue`
resumes a run that failed, and `npx hardhat migrate:verify` verifies later.
