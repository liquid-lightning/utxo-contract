import { expect } from "chai";

import type { BaseContract, ContractTransactionResponse } from "ethers";

import { type Env, SUBMIT_GAS, expectCustomError } from "./ledger.js";
import { type AssetCaseJson, type AssetPrevoutJson, assetPrevout, hex, isExit, isOpReturn } from "./vectors.js";

interface Out {
  txid: string;
  vout: number;
  asset: string;
  amount: bigint;
  script: string;
  height: number;
}

/** What the ledger needs from the multi-asset chain mock. */
export interface MultiChainLike extends BaseContract {
  submit: any;
  seed: any;
  validateAt: any;
  isUnspent: any;
  withdrawable: any;
  owed: any;
}

/**
 * The multi-asset chain mock plus an independent ledger of what it should
 * hold in each asset, with the per-asset invariant checked against the
 * contract's own state. Assets are named by their tags in hex (no prefix).
 */
export class AssetLedger {
  readonly outs: Out[] = [];
  /** `${account}|${asset}` => the asset's smallest units owed. */
  readonly owed = new Map<string, bigint>();
  readonly burned = new Map<string, bigint>();

  constructor(
    readonly env: Env,
    readonly chain: MultiChainLike,
    /** asset => its smallest units per sat */
    readonly units: Map<string, bigint>,
    readonly feeAsset: string,
    readonly genesis: bigint,
    readonly interval: bigint,
    /** What the chain holds of an asset: its ETH, or its balance of the token. */
    readonly held: (asset: string) => Promise<bigint>,
    /** Mints `units` of a token to the chain, to back seeded outputs. */
    readonly mint: (asset: string, units: bigint) => Promise<void>,
    /** Who submits (and so gets the fees) unless a case says otherwise. */
    readonly submitter: string,
  ) {}

  unit(asset: string): bigint {
    const unit = this.units.get(asset);

    if (unit === undefined) {
      throw new Error(`unknown asset ${asset}`);
    }

    return unit;
  }

  /** Makes the next transaction apply at `height`. False if the clock is already past it. */
  async at(height: number): Promise<boolean> {
    const target = this.genesis + BigInt(height) * this.interval;
    const latest = BigInt(await this.env.networkHelpers.time.latest());

    if (latest < target) {
      await this.env.networkHelpers.time.setNextBlockTimestamp(target);

      return true;
    }

    return latest + 1n < target + this.interval;
  }

  async seed(seeds: { txid: string; vout: number; prevout: AssetPrevoutJson }[]) {
    if (seeds.length == 0) {
      return;
    }

    let value = 0n;

    for (const { prevout } of seeds) {
      const units = BigInt(prevout.amount) * this.unit(prevout.asset);

      if (prevout.asset == this.feeAsset) {
        value += units;
      } else {
        await this.mint(prevout.asset, units);
      }
    }

    await this.chain.seed(
      seeds.map((s) => hex(s.txid)),
      seeds.map((s) => s.vout),
      seeds.map((s) => assetPrevout(s.prevout)),
      { value },
    );

    for (const s of seeds) {
      this.record(s.txid, s.vout, s.prevout.asset, BigInt(s.prevout.amount), s.prevout.script, s.prevout.height);
    }
  }

  record(txid: string, vout: number, asset: string, amount: bigint, script: string, height: number) {
    this.outs.push({ txid, vout, asset, amount, script, height });
  }

  async seedCase(c: AssetCaseJson, all = false) {
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
  async submitValid(c: AssetCaseJson, submit?: () => Promise<ContractTransactionResponse>, feeTo?: string) {
    const pv = c.prevouts.map(assetPrevout);

    await this.seedCase(c);

    if (c.earlyError !== null) {
      if (await this.at(c.minHeight - 1)) {
        await expectCustomError(
          this.chain.submit(hex(c.rawTx), pv, { gasLimit: SUBMIT_GAS }),
          this.chain,
          c.earlyError,
        );
      } else {
        await expectCustomError(this.chain.validateAt(hex(c.rawTx), pv, c.minHeight - 1), this.chain, c.earlyError);
      }
    }

    expect(await this.at(c.height), `${c.name}: the clock is past its height`).to.be.true;

    const tx = submit ? submit() : this.chain.submit(hex(c.rawTx), pv, { gasLimit: SUBMIT_GAS });

    await expect(tx).to.emit(this.chain, "TxApplied").withArgs(c.height, hex(c.txid), hex(c.rawTx));

    await this.applied(c, feeTo ?? this.submitter);
  }

  /** The ledger after `c` was applied, checked against the contract. */
  async applied(c: AssetCaseJson, feeTo: string) {
    for (let i = 0; i < c.prevouts.length; ++i) {
      const p = c.prevouts[i];

      expect(
        await this.chain.isUnspent(hex(c.inTxids[i]), c.inVouts[i], hex(p.asset), p.amount, hex(p.script), p.height),
        `${c.name}: input ${i} still unspent`,
      ).to.be.false;
    }

    for (let j = 0; j < c.outs.length; ++j) {
      const { asset, amount, script } = c.outs[j];
      const units = BigInt(amount) * this.unit(asset);
      const stored = await this.chain.isUnspent(hex(c.txid), j, hex(asset), amount, hex(script), c.height);

      if (script.length == 0) {
        this.credit(feeTo, asset, units);
        expect(stored, `${c.name}: fee output stored`).to.be.false;
      } else if (isExit(script)) {
        this.credit(this.env.ethers.getAddress(hex(script.slice(4))), asset, units);
        expect(stored, `${c.name}: exit stored`).to.be.false;
      } else if (isOpReturn(script)) {
        this.burned.set(asset, (this.burned.get(asset) ?? 0n) + units);
        expect(stored, `${c.name}: OP_RETURN stored`).to.be.false;
      } else {
        expect(stored, `${c.name}: output ${j}`).to.be.true;
        this.record(c.txid, j, asset, BigInt(amount), script, c.height);
      }
    }

    await this.checkInvariant();
  }

  credit(account: string, asset: string, units: bigint) {
    if (units != 0n) {
      const key = `${account}|${asset}`;

      this.owed.set(key, (this.owed.get(key) ?? 0n) + units);
    }
  }

  settle(account: string, asset: string) {
    this.owed.set(`${account}|${asset}`, 0n);
  }

  /**
   * For every asset: the contract's `owed` is the asset's UTXOs plus its
   * `withdrawable`, and its balance is that plus the OP_RETURN amounts burned.
   */
  async checkInvariant() {
    for (const [asset, unit] of this.units) {
      let live = 0n;

      for (const o of this.outs.filter((o) => o.asset == asset)) {
        if (await this.chain.isUnspent(hex(o.txid), o.vout, hex(o.asset), o.amount, hex(o.script), o.height)) {
          live += o.amount;
        }
      }

      let owedSum = 0n;

      for (const [key, amount] of this.owed) {
        const [account, owedAsset] = key.split("|");

        if (owedAsset == asset) {
          expect(await this.chain.withdrawable(account, hex(asset)), `withdrawable of ${key}`).to.eq(amount);
          owedSum += amount;
        }
      }

      expect(await this.chain.owed(hex(asset)), `owed of ${asset}`).to.eq(live * unit + owedSum);
      expect(await this.held(asset), `balance of ${asset}`).to.eq(
        live * unit + owedSum + (this.burned.get(asset) ?? 0n),
      );
    }
  }

  /** The (account, asset) pairs that are owed something, with the amounts. */
  owing(): [string, string, bigint][] {
    return [...this.owed]
      .filter(([, amount]) => amount != 0n)
      .map(([key, amount]) => [...key.split("|"), amount] as [string, string, bigint]);
  }
}
