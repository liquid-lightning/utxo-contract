# UtxoChain contracts

Two generations of the contract, in one Hardhat project laid out the
[Solarity](https://github.com/dl-solarity) way:

- **v1**, the contract of `SPEC.md` section 4 (in the
  [evm-plugin](https://github.com/liquid-lightning/evm-plugin) repository):
  one coin per instance, spent by Bitcoin-format transactions.
- **v2**, `MultiUtxoChain`: ETH and many ERC-20 tokens in one instance, spent
  by Elements-format transactions, so that Core Lightning's asset-channel
  code can run on it as it does on Liquid.

```
contracts/
  v1/                 AUtxoChain (the logic), UtxoChain (ETH), UtxoChainToken (one ERC-20)
  v2/                 MultiUtxoChain (ETH and registered ERC-20s)
  interfaces/         the NatSpec lives here
  libs/bitcoin/       transaction parser, BIP143 and BIP341 sighashes, script templates, validation
  libs/elements/      Elements transaction parser, signature hash and validation (v2)
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

The v1 contracts have no dependencies; v2 uses OpenZeppelin's `Ownable`. All
need solc 0.8.30 and the Osaka EVM (EIP-7883 modexp pricing).

## v2: MultiUtxoChain

Every output carries the asset it holds, as on Liquid, and a transaction may
move several assets. What differs from v1:

- **Format.** The explicit subset of Elements transactions: an output is its
  asset tag, its value, an empty nonce and its script. Confidential outputs,
  issuances and peg-ins are rejected. The signature hash is Elements' for
  segwit v0. The script templates are v1's, without taproot (Core Lightning
  does not use it on Elements).
- **Assets.** An asset is named by the 32 bytes of its tag as serialized.
  ETH is the fee asset, `FEE_ASSET`: the L-BTC tag of the Liquid-type network
  the nodes run with, so they treat ETH as their native coin. A token's asset
  is its address, zero-padded to 32 bytes and byte-reversed, so the asset id
  that lightningd and Elements tools print is the padded address.
- **Registry.** The owner registers tokens (`registerToken`). Rebasing tokens,
  tokens that can turn on a transfer fee, and tokens with two addresses for
  one balance must not be registered: the last would back two assets with one
  balance.
- **Amounts.** For each asset the inputs equal the outputs, exactly. A fee is
  an output with an empty script, in any asset, credited to whoever submits
  the transaction. No transaction can move value between assets.
- **Accounting.** `withdrawable` and `withdraw` are per asset, and
  `owed(asset)` is what the chain owes in it, so the invariant
  `balance >= owed` can be watched for each asset.
- **Deposits.** `depositNative(script)` for ETH and
  `deposit(token, amount, script)` for a token. The script may not be empty
  (that would be a fee output).

`MultiUtxoChain` is 24,445 bytes, 131 under the limit.

Not done yet: the specification text for v2 (SPEC.md covers v1), a
reference validator and fuzzer for the Elements format, and vectors recorded
from Core Lightning itself. The v2 vectors are built by a generator that
follows the shapes of the asset-channel transactions.

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
- `test/v2/MultiUtxoChain.test.ts`: the transactions of an asset channel's
  life (funding with a fee reserve, a two-input commitment, HTLC
  transactions, sweeps, penalties, anchor spends, an exit) for a 6-decimal
  token, an 18-decimal token and ETH; a mutual close; every hash type; 49
  tampered transactions; deposits byte for byte; per-asset withdrawals,
  re-entrancy, the tokens the contract must refuse, and the per-asset
  invariant after every step.
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

`test/data/v2/vectors.json` comes from the same repository:

```
python3 -I v2/gen_vectors.py --out ../utxo-contract/evm/test/data/v2
```

With `wallycore` installed (libwally, the library lightningd uses for
Elements), the generator checks every transaction's serialization, txid and
signature hashes against it. The vectors are built for the addresses that the
tests' chain and tokens get: the first three contracts of the first account
of a Hardhat network.

## Deploying

`deploy/config/index.ts` holds the virtual block interval per chain id (2 s
on a local node, 60 s on Base Sepolia), the tokens to deploy a
`UtxoChainToken` for (`UTXO_TOKENS=0x...,0x...` adds tokens for one run), and
v2's fee asset, owner and tokens.

```
npm run private-network          # in another terminal
npm run deploy-localhost

cp .env.example .env             # PRIVATE_KEY, BASE_SEPOLIA_RPC_URL, ETHERSCAN_KEY
npm run deploy-base-sepolia      # deploys and verifies
```

Migration 1 deploys `UtxoChain`; migration 2 deploys one `UtxoChainToken`
per configured token, reading its `decimals()` for the units per sat.
Migration 3 deploys `MultiUtxoChain` with the chain's fee asset, registers
the configured tokens (`multiTokens`, or `MULTI_TOKENS=0x...,0x...`) and
hands it to the configured owner. `npx hardhat migrate --only 3` runs one. A
report of the run is written under `cache/`. `npx hardhat migrate --continue`
resumes a run that failed, and `npx hardhat migrate:verify` verifies later.
