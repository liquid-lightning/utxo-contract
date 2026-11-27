import { expect } from "chai";
import hre from "hardhat";

import { hex, readJson } from "@test-helpers";

import type { SchnorrMock, SighashMock } from "@ethers-v6";

const { ethers } = await hre.network.create();

interface Bip341KeyPath {
  rawUnsignedTx: string;
  utxosSpent: { amountSats: number; scriptPubKey: string }[];
  intermediary: Record<string, string>;
  inputSpending: { txinIndex: number; hashType: number; sigMsg: string; sigHash: string; witness: string[] }[];
}

const V = readJson<Bip341KeyPath>("bip341-keypath.json");

describe("TaprootSighash", () => {
  let sighash: SighashMock;
  let schnorr: SchnorrMock;

  const rawTx = hex(V.rawUnsignedTx);
  const spent = V.utxosSpent.map((u) => ({ amount: u.amountSats, scriptPubKey: hex(u.scriptPubKey), height: 0 }));

  before(async () => {
    sighash = await ethers.deployContract("SighashMock");
    schnorr = await ethers.deployContract("SchnorrMock");
  });

  describe("#sigMsg", () => {
    it("should use the TapSighash tag", async () => {
      expect(await sighash.tag()).to.eq(ethers.sha256(ethers.toUtf8Bytes("TapSighash")));
    });

    it("should compute the five hashes of the BIP341 key path vector", async () => {
      const i = V.intermediary;

      expect(await sighash.hashes(rawTx, spent)).to.deep.eq(
        [i.hashAmounts, i.hashOutputs, i.hashPrevouts, i.hashScriptPubkeys, i.hashSequences].map(hex),
      );
    });

    it("should match the message, hash and signature of each of the 7 inputs", async () => {
      const seen = new Set<number>();

      for (const v of V.inputSpending) {
        seen.add(v.hashType);

        expect(await sighash.sigMsg(rawTx, spent, v.txinIndex, v.hashType)).to.eq(hex(v.sigMsg));
        expect(await sighash.sigHash(rawTx, spent, v.txinIndex, v.hashType)).to.eq(hex(v.sigHash));

        const key = hex(V.utxosSpent[v.txinIndex].scriptPubKey.slice(4));
        const rx = BigInt(hex(v.witness[0].slice(0, 64)));
        const s = BigInt(hex(v.witness[0].slice(64, 128)));

        expect(await schnorr.verify(key, hex(v.sigHash), rx, s)).to.be.true;
        expect(await schnorr.verify(key, ethers.toBeHex(BigInt(hex(v.sigHash)) ^ 1n, 32), rx, s)).to.be.false;
      }

      // DEFAULT, ALL, NONE, SINGLE and the three ANYONECANPAY ones
      expect([...seen].sort((a, b) => a - b)).to.deep.eq([0, 1, 2, 3, 0x81, 0x82, 0x83]);
    });
  });
});
