import { expect } from "chai";
import hre from "hardhat";

import type { EventLog } from "ethers";

import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/types";

import {
  type BadJson,
  type CaseJson,
  Ledger,
  Reverter,
  SUBMIT_GAS,
  type VectorsV1,
  expectCustomError,
  hex,
  isExit,
  prevout,
  readJson,
} from "@test-helpers";

import type { ReentererMock, UtxoChainMock } from "@ethers-v6";

const { ethers, networkHelpers } = await hre.network.create();

const V = readJson<VectorsV1>("v1/vectors.json");
const REVIEW = readJson<any>("v1/review.json");

const SAT = 10n ** 10n;
const MAX_MONEY = 21_000_000n * 100_000_000n;
const P2WPKH = "0x0014aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const P2TR = "0x5120aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

describe("UtxoChain", () => {
  const reverter = new Reverter(networkHelpers);

  const GENESIS = BigInt(V.genesisTime);
  const INTERVAL = BigInt(V.interval);

  let OWNER: HardhatEthersSigner;

  let chain: UtxoChainMock;
  let ledger: Ledger;

  /** A fresh chain whose block 0 is at `genesis`, and its ledger. */
  async function deploy(genesis = GENESIS, interval = INTERVAL) {
    await reverter.revert();
    await networkHelpers.time.setNextBlockTimestamp(genesis);

    chain = await ethers.deployContract("UtxoChainMock", [interval]);

    track(genesis, interval);
  }

  function track(genesis: bigint, interval: bigint) {
    ledger = new Ledger(
      { ethers, networkHelpers },
      chain,
      SAT,
      genesis,
      interval,
      async () => ethers.provider.getBalance(chain),
      async (units) => units,
      OWNER.address,
    );
  }

  async function deposit(value: bigint, script: string) {
    const receipt = await (await chain.deposit(script, { value })).wait();
    const { height, txid } = (receipt!.logs[0] as EventLog).args;

    const amount = value / SAT;

    expect(await chain.isUnspent(txid, 0, amount, script, height)).to.be.true;

    ledger.record(txid.slice(2), 0, amount, script.slice(2), Number(height));
    await ledger.checkInvariant();

    return txid as string;
  }

  async function impersonate(address: string) {
    await networkHelpers.impersonateAccount(address);
    await networkHelpers.setBalance(address, 10n ** 18n);

    return ethers.getSigner(address);
  }

  /** Seeds synthetic case 0 and has `reenterer` submit it, so the fee is owed to it. */
  async function feeTo(reenterer: ReentererMock) {
    const c = V.synthetic[0];
    const address = await reenterer.getAddress();

    await ledger.seedCase(c, true);
    await ledger.at(c.height);
    await reenterer.submit(hex(c.rawTx), c.prevouts.map(prevout), { gasLimit: SUBMIT_GAS });

    const fee = BigInt(c.fee) * SAT;

    expect(fee).to.not.eq(0n);
    expect(await chain.withdrawable(address)).to.eq(fee);

    await ledger.applied(c, address);

    return fee;
  }

  before(async () => {
    [OWNER] = await ethers.getSigners();

    await networkHelpers.setBalance(OWNER.address, 10n ** 30n);

    await reverter.snapshot();
  });

  describe("#constructor", () => {
    it("should set parameters correctly", async () => {
      await deploy();

      expect(await chain.GENESIS_TIME()).to.eq(GENESIS);
      expect(await chain.INTERVAL()).to.eq(INTERVAL);
      expect(await chain.DEPLOY_BLOCK()).to.eq(await ethers.provider.getBlockNumber());
      expect(await chain.depositNonce()).to.eq(0);
      expect(await chain.txCount()).to.eq(0);
      expect(await chain.logHash()).to.eq(ethers.ZeroHash);
    });

    it("should revert if the interval is zero", async () => {
      await deploy();

      await expect(ethers.deployContract("UtxoChainMock", [0])).to.be.revertedWithCustomError(chain, "BadInterval");
    });
  });

  describe("#height", () => {
    it("should follow the clock", async () => {
      await deploy();

      expect(await chain.height()).to.eq(0);

      await networkHelpers.time.increaseTo(GENESIS + INTERVAL - 1n);
      expect(await chain.height()).to.eq(0);

      await networkHelpers.time.increaseTo(GENESIS + 5n * INTERVAL);
      expect(await chain.height()).to.eq(5);

      await networkHelpers.time.increaseTo(GENESIS + 6n * INTERVAL - 1n);
      expect(await chain.height()).to.eq(5);
    });

    it("should revert past 2^32 - 1 virtual blocks", async () => {
      await deploy();

      await networkHelpers.time.increaseTo(GENESIS + 2n ** 32n * INTERVAL);

      await expect(chain.height()).to.be.revertedWithCustomError(chain, "HeightOverflow");
    });
  });

  describe("#deposit", () => {
    it("should revert at height zero", async () => {
      await deploy();

      await expect(chain.deposit(P2WPKH, { value: SAT })).to.be.revertedWithCustomError(chain, "TooEarly");

      await ledger.at(1);
      await chain.deposit(P2WPKH, { value: SAT });
    });

    it("should revert if the value is not a whole number of sats within MAX_MONEY", async () => {
      await deploy();
      await ledger.at(1);

      for (const value of [0n, SAT - 1n, SAT + 1n, (MAX_MONEY + 1n) * SAT]) {
        await expect(chain.deposit(P2WPKH, { value })).to.be.revertedWithCustomError(chain, "BadDepositValue");
      }

      await deposit(MAX_MONEY * SAT, P2WPKH);
    });

    it("should revert if the script is too long, an exit or an OP_RETURN", async () => {
      await deploy();
      await ledger.at(1);

      const bad = [
        hex("00".repeat(10_001)),
        "0x60141111111111111111111111111111111111111111",
        "0x6a",
        "0x6a0401020304",
      ];

      for (const script of bad) {
        await expect(chain.deposit(script, { value: SAT })).to.be.revertedWithCustomError(chain, "BadDepositScript");
      }
    });

    it("should accept any other script", async () => {
      await deploy();
      await ledger.at(1);

      await deposit(SAT, hex("00".repeat(10_000)));
      // never spendable, but allowed (SPEC 4.2)
      await deposit(SAT, "0x");
      // v16 with 19 and with 21 bytes: not exits
      await deposit(SAT, "0x601311111111111111111111111111111111111111");
      await deposit(SAT, "0x6014111111111111111111111111111111111111111100");
    });

    it("should build the deposit transactions of SPEC 3.3 byte for byte", async () => {
      await deploy();

      // The generator built them for a contract at this address on chain 31337.
      await networkHelpers.setCode(V.deposits.address, await ethers.provider.getCode(chain));
      chain = chain.attach(V.deposits.address) as UtxoChainMock;
      track(GENESIS, INTERVAL);

      expect((await ethers.provider.getNetwork()).chainId).to.eq(V.deposits.chainId);

      await ledger.at(5);

      for (let i = 0; i < V.deposits.txs.length; ++i) {
        const d = V.deposits.txs[i];
        const value = BigInt(d.amount) * SAT;

        await expect(chain.deposit(hex(d.script), { value }))
          .to.emit(chain, "TxApplied")
          .withArgs(5, hex(d.txid), hex(d.rawTx));

        expect(ethers.sha256(ethers.sha256(hex(d.rawTx)))).to.eq(hex(d.txid));
        expect(await chain.isUnspent(hex(d.txid), 0, d.amount, hex(d.script), 5)).to.be.true;
        expect(await chain.depositNonce()).to.eq(i + 1);

        ledger.record(d.txid, 0, BigInt(d.amount), d.script, 5);
        await ledger.checkInvariant();
      }

      await ledger.submitValid(V.deposits.spend);
    });
  });

  describe("#utxoKey", () => {
    it("should hash the txid and the output index", async () => {
      await deploy();

      const txid = ethers.id("tx");

      expect(await chain.utxoKey(txid, 7)).to.eq(ethers.solidityPackedKeccak256(["bytes32", "uint32"], [txid, 7]));
    });
  });

  describe("#isUnspent", () => {
    it("should match exactly the output that was stored", async () => {
      await deploy();

      const txid = ethers.id("tx");
      const p = { amount: 1234, script: P2TR.slice(2), height: 3 };

      await ledger.seed([{ txid: txid.slice(2), vout: 7, prevout: p }]);

      expect(await chain.utxo(await chain.utxoKey(txid, 7))).to.eq(
        ethers.solidityPackedKeccak256(["uint64", "bytes", "uint32"], [1234, P2TR, 3]),
      );

      expect(await chain.isUnspent(txid, 7, 1234, P2TR, 3)).to.be.true;
      expect(await chain.isUnspent(txid, 7, 1235, P2TR, 3)).to.be.false;
      expect(await chain.isUnspent(txid, 7, 1234, P2TR, 4)).to.be.false;
      expect(await chain.isUnspent(txid, 7, 1234, "0x5120", 3)).to.be.false;
      expect(await chain.isUnspent(txid, 6, 1234, P2TR, 3)).to.be.false;
    });
  });

  describe("#submit", () => {
    it("should revert at height zero", async () => {
      await deploy();

      const c = V.synthetic[0];

      await expect(chain.submit(hex(c.rawTx), c.prevouts.map(prevout))).to.be.revertedWithCustomError(
        chain,
        "TooEarly",
      );
    });

    for (const file of V.real) {
      it(`should replay every real CLN transaction of ${file.file}`, async () => {
        await deploy();

        expect(file.cases.length).to.be.greaterThan(0);

        for (const c of file.cases) {
          await ledger.submitValid(c);
        }
      });
    }

    it("should apply every synthetic transaction", async () => {
      for (const c of V.synthetic) {
        await deploy();
        await ledger.submitValid(c);
      }
    });

    const badByError = new Map<string, BadJson[]>();

    for (const b of V.bad) {
      badByError.set(b.err.name, [...(badByError.get(b.err.name) ?? []), b]);
    }

    for (const [name, cases] of badByError) {
      it(`should revert with ${name} (${cases.length} tampered transactions)`, async () => {
        for (const b of cases) {
          await deploy();
          await ledger.seed(b.seeds.map((s) => ({ txid: s.txid, vout: s.vout, prevout: s })));
          await ledger.at(b.height);

          try {
            await expectCustomError(
              chain.submit(hex(b.rawTx), b.prevouts.map(prevout), { gasLimit: SUBMIT_GAS }),
              chain,
              b.err,
            );
          } catch (e) {
            throw new Error(`${b.name}: ${(e as Error).message}`);
          }
        }
      });
    }

    it("should apply the worst-case commitment under 12M gas", async () => {
      await deploy();

      const c = V.worstCase;

      await ledger.seedCase(c, true);
      await ledger.at(c.height);

      const tx = await chain.submit(hex(c.rawTx), c.prevouts.map(prevout), { gasLimit: SUBMIT_GAS });
      const receipt = await tx.wait();

      expect(receipt!.gasUsed).to.be.lessThan(12_000_000n);

      await ledger.applied(c, OWNER.address);
    });

    it("should accept a template whose off-curve key is on the unused path", async () => {
      await deploy(BigInt(REVIEW.genesisTime), BigInt(REVIEW.interval));

      const p = { amount: 10_000, script: REVIEW.toLocalBadDelayedKey.script, height: 1 };

      await ledger.seed([{ txid: REVIEW.prevTxid, vout: 0, prevout: p }]);
      await ledger.at(5);

      await chain.submit(hex(REVIEW.toLocalBadDelayedKey.rawTx), [prevout(p)], { gasLimit: SUBMIT_GAS });
    });

    it("should revert if a to_local delay is above a u32", async () => {
      await deploy(BigInt(REVIEW.genesisTime), BigInt(REVIEW.interval));

      const p = { amount: 10_000, script: REVIEW.toLocalDelay2pow32.script, height: 1 };

      await ledger.seed([{ txid: REVIEW.prevTxid, vout: 0, prevout: p }]);
      await ledger.at(5);

      await expect(chain.submit(hex(REVIEW.toLocalDelay2pow32.rawTx), [prevout(p)], { gasLimit: SUBMIT_GAS }))
        .to.be.revertedWithCustomError(chain, "UnknownWitnessScript")
        .withArgs(0);
    });
  });

  describe("#withdraw", () => {
    it("should pay exits and fees once", async () => {
      await deploy();

      const c: CaseJson = V.synthetic[V.exitCase];

      await ledger.submitValid(c);

      const exit = c.outs.find((o) => isExit(o.script))!;
      const to = ethers.getAddress(hex(exit.script.slice(4)));
      const amount = BigInt(exit.amount) * SAT;

      expect(amount).to.not.eq(0n);
      expect(await chain.withdrawable(to)).to.eq(amount);

      const payee = await impersonate(to);

      await expect(chain.connect(payee).withdraw()).to.changeEtherBalance(ethers, to, amount);

      ledger.owed.set(to, 0n);
      await ledger.checkInvariant();

      await expect(chain.connect(payee).withdraw()).to.be.revertedWithCustomError(chain, "NothingToWithdraw");

      const fee = BigInt(c.fee) * SAT;

      expect(fee).to.not.eq(0n);

      await expect(chain.withdraw()).to.changeEtherBalance(ethers, OWNER, fee);

      ledger.owed.set(OWNER.address, 0n);
      await ledger.checkInvariant();
    });

    it("should pay a recipient that re-enters only once", async () => {
      await deploy();

      const reenterer = await ethers.deployContract("ReentererMock", [chain, false]);
      const address = await reenterer.getAddress();
      const fee = await feeTo(reenterer);

      await expect(reenterer.attack({ gasLimit: 2_000_000n })).to.changeEtherBalances(
        ethers,
        [chain, reenterer],
        [-fee, fee],
      );

      expect(await reenterer.received()).to.eq(fee);
      expect(await reenterer.calls()).to.eq(1);
      expect(await reenterer.innerError()).to.eq(chain.interface.encodeErrorResult("NothingToWithdraw"));
      expect(await chain.withdrawable(address)).to.eq(0);

      ledger.owed.set(address, 0n);
      await ledger.checkInvariant();
    });

    it("should revert if the recipient reverts, and keep its balance", async () => {
      await deploy();

      const reenterer = await ethers.deployContract("ReentererMock", [chain, true]);
      const fee = await feeTo(reenterer);

      await expect(reenterer.attack({ gasLimit: 2_000_000n })).to.be.revertedWithCustomError(chain, "WithdrawFailed");

      expect(await chain.withdrawable(reenterer)).to.eq(fee);

      await ledger.checkInvariant();
    });
  });

  describe("#logHash", () => {
    for (const file of V.real) {
      it(`should chain every deposit and transaction of ${file.file}`, async () => {
        await deploy();

        let count = 0n;
        let hash = ethers.ZeroHash;

        const expectLog = async (height: number, txid: string) => {
          count += 1n;
          hash = ethers.solidityPackedKeccak256(["bytes32", "uint32", "bytes32"], [hash, height, txid]);

          expect(await chain.txCount()).to.eq(count);
          expect(await chain.logHash()).to.eq(hash);
        };

        for (let i = 0; i < file.cases.length; ++i) {
          const c = file.cases[i];

          // a deposit before each transaction; a rejected (early) submit changes neither
          await ledger.at(c.height);
          await expectLog(
            c.height,
            await deposit(SAT * BigInt(i + 1), ethers.concat(["0x0014", ethers.toBeHex(i, 20)])),
          );

          await ledger.submitValid(c);
          await expectLog(c.height, hex(c.txid));
        }
      });
    }
  });
});
