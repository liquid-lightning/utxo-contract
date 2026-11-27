import { expect } from "chai";
import hre from "hardhat";

import type { Secp256k1Mock } from "@ethers-v6";

const { ethers } = await hre.network.create();

const P = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2fn;
const GX = 0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798n;
const GY = 0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8n;

describe("Secp256k1", () => {
  let secp256k1: Secp256k1Mock;

  before(async () => {
    secp256k1 = await ethers.deployContract("Secp256k1Mock");
  });

  describe("#liftX", () => {
    it("should return the y of the given parity", async () => {
      expect(await secp256k1.liftX(GX, 0)).to.deep.eq([true, GY]);
      expect(await secp256k1.liftX(GX, 1)).to.deep.eq([true, P - GY]);
    });

    it("should fail if x is not the x of a curve point", async () => {
      for (const x of [0n, 5n, P, P + 1n]) {
        expect((await secp256k1.liftX(x, 0))[0], `x = ${x}`).to.be.false;
      }
    });
  });
});
