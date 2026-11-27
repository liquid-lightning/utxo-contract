import { expect } from "chai";
import hre from "hardhat";

import { hex, readJson } from "@test-helpers";

import type { SchnorrMock } from "@ethers-v6";

const { ethers } = await hre.network.create();

interface Bip340Vector {
  index: number;
  "public key": string;
  message: string;
  signature: string;
  "verification result": boolean;
}

const VECTORS = readJson<{ vectors: Bip340Vector[] }>("bip340-vectors.json").vectors;

const P = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2fn;
const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;

function split(signature: string): [bigint, bigint] {
  return [BigInt(hex(signature.slice(0, 64))), BigInt(hex(signature.slice(64)))];
}

function flip(data: string, bit: number): string {
  const bytes = ethers.getBytes(hex(data));

  bytes[bit >> 3] ^= 1 << (bit & 7);

  return ethers.hexlify(bytes);
}

describe("Schnorr", () => {
  let schnorr: SchnorrMock;

  before(async () => {
    schnorr = await ethers.deployContract("SchnorrMock");
  });

  describe("#verifyBytes", () => {
    it("should use the BIP340 challenge tag", async () => {
      expect(await schnorr.challengeTag()).to.eq(ethers.sha256(ethers.toUtf8Bytes("BIP0340/challenge")));
    });

    it("should agree with all 19 official BIP340 vectors", async () => {
      let valid = 0;

      for (const v of VECTORS) {
        const [rx, s] = split(v.signature);
        const ok = v["verification result"];

        expect(await schnorr.verifyBytes(hex(v["public key"]), hex(v.message), rx, s), `vector ${v.index}`).to.eq(ok);

        if (v.message.length == 64) {
          expect(await schnorr.verify(hex(v["public key"]), hex(v.message), rx, s), `vector ${v.index}`).to.eq(ok);
        }

        valid += ok ? 1 : 0;
      }

      expect(VECTORS.length).to.eq(19);
      expect(valid).to.eq(9);
    });

    it("should reject a valid vector with a flipped bit", async () => {
      for (const v of VECTORS.filter((v) => v["verification result"])) {
        const key = hex(v["public key"]);
        const [rx, s] = split(v.signature);

        for (let bit = 0; bit < 512; bit += 37) {
          const [badRx, badS] = split(flip(v.signature, bit).slice(2));

          expect(await schnorr.verifyBytes(key, hex(v.message), badRx, badS), "signature bit").to.be.false;
        }

        for (let bit = 0; bit < 4 * v.message.length; bit += 29) {
          expect(await schnorr.verifyBytes(key, flip(v.message, bit), rx, s), "message bit").to.be.false;
        }

        for (let bit = 0; bit < 256; bit += 23) {
          expect(await schnorr.verifyBytes(flip(v["public key"], bit), hex(v.message), rx, s), "key bit").to.be.false;
        }
      }
    });

    it("should reject s = 0, s = n and r = p", async () => {
      for (const v of VECTORS.filter((v) => v["verification result"])) {
        const key = hex(v["public key"]);
        const [rx, s] = split(v.signature);

        expect(await schnorr.verifyBytes(key, hex(v.message), rx, 0)).to.be.false;
        expect(await schnorr.verifyBytes(key, hex(v.message), rx, N)).to.be.false;
        expect(await schnorr.verifyBytes(key, hex(v.message), P, s)).to.be.false;
      }
    });
  });
});
