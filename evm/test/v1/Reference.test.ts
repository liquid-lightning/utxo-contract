import { expect } from "chai";
import hre from "hardhat";

import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/types";

import { type PrevoutJson, Reverter, SUBMIT_GAS, hex, prevout, readJsonLines } from "@test-helpers";

import type { UtxoChainMock } from "@ethers-v6";

const { ethers, networkHelpers } = await hre.network.create();

interface RefCase {
  tx: string;
  prevouts: (PrevoutJson & { mint?: boolean })[];
  height: number;
  genesis_time: number;
  interval: number;
  valid: boolean;
  error: string | null;
  origin: string;
}

interface RefDeposit {
  chain_id: number;
  contract: string;
  nonce: number | string;
  value_wei: number | string;
  script: string;
  height: number;
  valid: boolean;
  txid: string | null;
  origin: string;
}

const SAT = 10n ** 10n;
const GENESIS = 1_700_000_000n;
const INTERVAL = 600n;

/**
 * The outpoints of a transaction the contract may reject, for seeding (as
 * gen_vectors.py's lenient_parse): empty if they can't be read.
 */
function outpoints(rawTx: string): { txid: string; vout: number }[] {
  const raw = ethers.getBytes(hex(rawTx));
  const out: { txid: string; vout: number }[] = [];

  try {
    let o = raw[4] == 0 ? 6 : 4;
    const n = raw[o++];

    for (let i = 0; i < n; ++i) {
      if (o + 41 > raw.length) {
        return [];
      }

      out.push({
        txid: ethers.hexlify(raw.subarray(o, o + 32)).slice(2),
        vout: new DataView(raw.buffer, raw.byteOffset + o + 32, 4).getUint32(0, true),
      });

      o += 41 + raw[o + 36];
    }
  } catch {
    return [];
  }

  return out;
}

/**
 * The differential test against the independent Python reference
 * (evm-plugin/reference): the contract accepts exactly the cases the
 * reference says are valid. Cases whose origin is marked ambiguous depend on
 * a reading of the SPEC; for them the contract may only be stricter.
 *
 * The cases are large and not in git: `export_json.py --full` (evm-plugin)
 * writes them to test/data/v1/full, and without them these tests are skipped.
 */
describe("Reference", () => {
  const reverter = new Reverter(networkHelpers);

  let OWNER: HardhatEthersSigner;

  let chain: UtxoChainMock;

  before(async () => {
    [OWNER] = await ethers.getSigners();

    await networkHelpers.setBalance(OWNER.address, 10n ** 40n);
    await networkHelpers.time.setNextBlockTimestamp(GENESIS);

    chain = await ethers.deployContract("UtxoChainMock", [INTERVAL]);

    await reverter.snapshot();
  });

  afterEach(reverter.revert);

  for (const file of ["cln.jsonl", "synth.jsonl"]) {
    const cases = readJsonLines<RefCase>(`v1/full/${file}`);

    it(`should accept exactly the transactions the reference accepts (${file})`, async function () {
      if (cases === null) {
        this.skip();
      }

      let accepted = 0;
      let stricter = 0;

      for (let n = 0; n < cases.length; ++n) {
        const c = cases[n];

        if (c.prevouts.some((p) => p.mint)) {
          continue;
        }

        expect([BigInt(c.genesis_time), BigInt(c.interval)]).to.deep.eq([GENESIS, INTERVAL]);

        await reverter.revert();

        const seeds = outpoints(c.tx).slice(0, c.prevouts.length);
        const total = seeds.reduce((sum, _, i) => sum + BigInt(c.prevouts[i].amount), 0n);

        await chain.seed(
          seeds.map((s) => hex(s.txid)),
          seeds.map((s) => s.vout),
          seeds.map((_, i) => prevout(c.prevouts[i])),
          { value: total * SAT },
        );

        const target = GENESIS + BigInt(c.height) * INTERVAL;

        if (BigInt(await networkHelpers.time.latest()) < target) {
          await networkHelpers.time.setNextBlockTimestamp(target);
        }

        let ok = true;

        try {
          await chain.submit(hex(c.tx), c.prevouts.map(prevout), { gasLimit: SUBMIT_GAS });
        } catch {
          ok = false;
        }

        if (ok != c.valid) {
          const ambiguous = c.origin.includes("ambiguous");

          expect(ambiguous && !ok, `${file} #${n} ${c.origin}: ${ok ? "accepted" : "rejected"}, reference: ${c.error}`)
            .to.be.true;

          stricter += 1;
        }

        accepted += ok ? 1 : 0;
      }

      console.log(`        ${cases.length} cases, ${accepted} accepted, ${stricter} ambiguous ones rejected`);
    });
  }

  for (const network of ["default", "simulatedBaseSepolia"]) {
    it(`should accept exactly the deposits the reference accepts, with the same txids (${network})`, async function () {
      const cases = readJsonLines<RefDeposit>("v1/full/deposits.jsonl");

      if (cases === null) {
        this.skip();
      }

      // A deposit's txid commits to the chain id, so each chain id has its network.
      const connection = await hre.network.create(network);
      const chainId = Number((await connection.ethers.provider.getNetwork()).chainId);
      const [owner] = await connection.ethers.getSigners();

      await connection.networkHelpers.setBalance(owner.address, 10n ** 40n);
      await connection.networkHelpers.time.setNextBlockTimestamp(GENESIS);

      const deployed = await connection.ethers.deployContract("UtxoChainMock", [INTERVAL]);
      const code = await connection.ethers.provider.getCode(deployed);
      const snapshot = await connection.networkHelpers.takeSnapshot();
      let ran = 0;

      for (const d of cases.filter((d) => d.chain_id == chainId)) {
        await snapshot.restore();
        await connection.networkHelpers.setCode(d.contract, code);

        const target = deployed.attach(d.contract) as UtxoChainMock;

        await target.setDepositNonce(BigInt(d.nonce));
        await connection.networkHelpers.time.setNextBlockTimestamp(GENESIS + BigInt(d.height) * INTERVAL);

        const tx = target.deposit(hex(d.script), { value: BigInt(d.value_wei) });

        if (d.valid) {
          // the reference prints txids in display order
          const txid = ethers.hexlify(ethers.getBytes(hex(d.txid!)).reverse());

          await expect(tx, d.origin)
            .to.emit(target, "TxApplied")
            .withArgs(d.height, txid, (raw: string) => !!raw);
        } else {
          await expect(tx, d.origin).to.be.revert(connection.ethers);
        }

        ran += 1;
      }

      expect(ran).to.be.greaterThan(0);

      console.log(`        ${ran} deposit cases on chain id ${chainId}`);
    });
  }
});
