import { expect } from "chai";

import type { BaseContract, ContractTransactionResponse } from "ethers";

import type { HardhatEthers } from "@nomicfoundation/hardhat-ethers/types";
import type { NetworkHelpers } from "@nomicfoundation/hardhat-network-helpers/types";

import { type CaseJson, type ErrJson, type PrevoutJson, hex, isExit, isOpReturn, prevout } from "./vectors.js";

/** The gas a submit may use: under Osaka's per-transaction cap (EIP-7825). */
export const SUBMIT_GAS = 16_000_000n;

export interface Env {
  ethers: HardhatEthers;
  networkHelpers: NetworkHelpers;
}

interface Out {
  txid: string;
  vout: number;
  amount: bigint;
  script: string;
  height: number;
}

/** What the ledger needs from a chain mock, whatever asset it holds. */
export interface ChainLike extends BaseContract {
  submit: any;
  withdraw: any;
  seed: any;
  validateAt: any;
  isUnspent: any;
  withdrawable: any;
}

export async function expectCustomError(call: Promise<unknown>, contract: BaseContract, err: ErrJson) {
  // (a string argument is a bytes32, in hex without its prefix)
  await expect(call)
    .to.be.revertedWithCustomError(contract, err.name)
    .withArgs(...err.args.map((arg) => (typeof arg == "string" ? hex(arg) : arg)));
}

/**
 * A chain mock plus an independent ledger of what it should hold, with the
 * SPEC 4.1 invariant checked against the contract's own state. `unit` is the
 * asset's smallest units per sat (wei, or token units).
 */
export class Ledger {
  readonly outs: Out[] = [];
  readonly owed = new Map<string, bigint>();
  burned = 0n;
  /** How many early-revert checks ran through `validateAt` because the clock had passed. */
  earlyByValidateAt = 0;

  constructor(
    readonly env: Env,
    readonly chain: ChainLike,
    readonly unit: bigint,
    readonly genesis: bigint,
    readonly interval: bigint,
    /** The asset the chain holds: its ETH, or its token balance. */
    readonly held: () => Promise<bigint>,
    /** Backs `units` of seeded outputs: returns the call's value, or mints the tokens. */
    readonly back: (units: bigint) => Promise<bigint>,
    /** Who submits (and so gets the fees) unless a case says otherwise. */
    readonly submitter: string,
  ) {
    this.owed.set(submitter, 0n);
  }

  timeOf(height: number): bigint {
    return this.genesis + BigInt(height) * this.interval;
  }

  /** Makes the next transaction apply at `height`. False if the clock is already past it. */
  async at(height: number): Promise<boolean> {
    const target = this.timeOf(height);
    const latest = BigInt(await this.env.networkHelpers.time.latest());

    if (latest < target) {
      await this.env.networkHelpers.time.setNextBlockTimestamp(target);

      return true;
    }

    return latest + 1n < target + this.interval;
  }

  async seed(seeds: { txid: string; vout: number; prevout: PrevoutJson }[]) {
    if (seeds.length == 0) {
      return;
    }

    const total = seeds.reduce((sum, s) => sum + BigInt(s.prevout.amount), 0n);
    const value = await this.back(total * this.unit);

    await this.chain.seed(
      seeds.map((s) => hex(s.txid)),
      seeds.map((s) => s.vout),
      seeds.map((s) => prevout(s.prevout)),
      { value },
    );

    for (const s of seeds) {
      this.record(s.txid, s.vout, BigInt(s.prevout.amount), s.prevout.script, s.prevout.height);
    }
  }

  record(txid: string, vout: number, amount: bigint, script: string, height: number) {
    this.outs.push({ txid, vout, amount, script, height });
  }

  async seedCase(c: CaseJson, all = false) {
    await this.seed(
      c.prevouts
        .map((p, i) => ({ txid: c.inTxids[i], vout: c.inVouts[i], prevout: p }))
        .filter((_, i) => all || c.seed[i]),
    );
  }

  /**
   * Submits a valid case after checking it fails one block before its
   * earliest valid height, and checks the event and the state after it.
   */
  async submitValid(c: CaseJson, submit?: () => Promise<ContractTransactionResponse>, feeTo?: string) {
    const pv = c.prevouts.map(prevout);

    await this.seedCase(c);

    if (c.earlyError !== null) {
      if (await this.at(c.minHeight - 1)) {
        await expectCustomError(
          this.chain.submit(hex(c.rawTx), pv, { gasLimit: SUBMIT_GAS }),
          this.chain,
          c.earlyError,
        );
      } else {
        this.earlyByValidateAt += 1;
        await expectCustomError(this.chain.validateAt(hex(c.rawTx), pv, c.minHeight - 1), this.chain, c.earlyError);
      }
    }

    expect(await this.at(c.height), `${c.name}: the clock is past its height`).to.be.true;

    const tx = submit ? submit() : this.chain.submit(hex(c.rawTx), pv, { gasLimit: SUBMIT_GAS });

    await expect(tx).to.emit(this.chain, "TxApplied").withArgs(c.height, hex(c.txid), hex(c.rawTx));

    await this.applied(c, feeTo ?? this.submitter);
  }

  /** The ledger after `c` was applied, checked against the contract. */
  async applied(c: CaseJson, feeTo: string) {
    for (let i = 0; i < c.prevouts.length; ++i) {
      const p = c.prevouts[i];

      expect(
        await this.chain.isUnspent(hex(c.inTxids[i]), c.inVouts[i], p.amount, hex(p.script), p.height),
        `${c.name}: input ${i} still unspent`,
      ).to.be.false;
    }

    this.credit(feeTo, BigInt(c.fee) * this.unit);

    for (let j = 0; j < c.outs.length; ++j) {
      const { amount, script } = c.outs[j];
      const stored = await this.chain.isUnspent(hex(c.txid), j, amount, hex(script), c.height);

      if (isExit(script)) {
        this.credit(this.env.ethers.getAddress(hex(script.slice(4))), BigInt(amount) * this.unit);
        expect(stored, `${c.name}: exit stored`).to.be.false;
      } else if (isOpReturn(script)) {
        this.burned += BigInt(amount) * this.unit;
        expect(stored, `${c.name}: OP_RETURN stored`).to.be.false;
      } else {
        expect(stored, `${c.name}: output ${j}`).to.be.true;
        this.record(c.txid, j, BigInt(amount), script, c.height);
      }
    }

    await this.checkInvariant();
  }

  credit(account: string, amount: bigint) {
    this.owed.set(account, (this.owed.get(account) ?? 0n) + amount);
  }

  /**
   * SPEC 4.1: balance >= sum(UTXO amounts) * unit + sum(withdrawable), and
   * with the ledger exactly: balance == that + the OP_RETURN amounts burned.
   */
  async checkInvariant() {
    let live = 0n;

    for (const o of this.outs) {
      if (await this.chain.isUnspent(hex(o.txid), o.vout, o.amount, hex(o.script), o.height)) {
        live += o.amount;
      }
    }

    let owedSum = 0n;

    for (const [account, amount] of this.owed) {
      expect(await this.chain.withdrawable(account), `withdrawable of ${account}`).to.eq(amount);
      owedSum += amount;
    }

    expect(await this.held(), "balance == UTXOs + withdrawable + burned").to.eq(
      live * this.unit + owedSum + this.burned,
    );
  }

  /** The payees that are owed something, with the amounts. */
  owing(): [string, bigint][] {
    return [...this.owed].filter(([, amount]) => amount != 0n);
  }
}
