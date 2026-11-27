import { expect } from "chai";
import hre from "hardhat";

import type { EventLog } from "ethers";

import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/types";

import { Ledger, Reverter, SUBMIT_GAS, type VectorsV1, hex, isExit, prevout, readJson } from "@test-helpers";

import type { ERC20Mock, TokenReentererMock, UtxoChainTokenMock } from "@ethers-v6";

const { ethers, networkHelpers } = await hre.network.create();

const V = readJson<VectorsV1>("v1/vectors.json");

const MAX_MONEY = 21_000_000n * 100_000_000n;
const P2WPKH = "0x0014aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const P2TR = "0x5120aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

// A hook that runs out of gas is ignored by the hook token, so gas estimation
// would settle on a limit that starves it: these calls get a fixed one.
const HOOK_GAS = { gasLimit: 2_000_000n };

/** 6 decimals: 1 sat = 1 unit. 18 decimals: 1 sat = 10^10 units. */
const DECIMALS: [number, bigint][] = [
  [6, 1n],
  [18, 10n ** 10n],
];

describe("UtxoChainToken", () => {
  const reverter = new Reverter(networkHelpers);

  const GENESIS = BigInt(V.genesisTime);
  const INTERVAL = BigInt(V.interval);

  let OWNER: HardhatEthersSigner;

  let token: ERC20Mock;
  let chain: UtxoChainTokenMock;
  let ledger: Ledger;

  /** A fresh token (of contract `tokenName`) and a chain for it whose block 0 is at GENESIS. */
  async function deploy(unit: bigint, tokenName = "ERC20Mock", tokenArgs: unknown[] = []) {
    await reverter.revert();

    token = (await ethers.deployContract(tokenName, tokenArgs)) as unknown as ERC20Mock;

    await networkHelpers.time.setNextBlockTimestamp(GENESIS);

    chain = await ethers.deployContract("UtxoChainTokenMock", [INTERVAL, token, unit]);

    track(unit);
  }

  function deployStandard(decimals: number, unit: bigint) {
    return deploy(unit, "ERC20Mock", [decimals]);
  }

  function track(unit: bigint) {
    ledger = new Ledger(
      { ethers, networkHelpers },
      chain,
      unit,
      GENESIS,
      INTERVAL,
      async () => token.balanceOf(chain),
      async (units) => {
        await token.mint(chain, units);

        return 0n;
      },
      OWNER.address,
    );
  }

  async function deposit(amount: bigint, script: string) {
    const receipt = await (await chain.deposit(amount, script)).wait();
    const log = receipt!.logs.find((l) => l.address == chain.target) as EventLog;
    const { height, txid } = log.args;
    const sats = amount / ledger.unit;

    expect(await chain.isUnspent(txid, 0, sats, script, height)).to.be.true;

    ledger.record(txid.slice(2), 0, sats, script.slice(2), Number(height));
    await ledger.checkInvariant();

    return txid as string;
  }

  async function impersonate(address: string) {
    await networkHelpers.impersonateAccount(address);
    await networkHelpers.setBalance(address, 10n ** 18n);

    return ethers.getSigner(address);
  }

  /**
   * Withdraws every payee's balance, checking each gets exactly what the
   * ledger says, in units, and the invariant after each.
   */
  async function drain() {
    for (const [account, amount] of ledger.owing()) {
      const payee = account == OWNER.address ? OWNER : await impersonate(account);

      await expect(chain.connect(payee).withdraw()).to.changeTokenBalance(ethers, token, account, amount);

      ledger.owed.set(account, 0n);
      await ledger.checkInvariant();

      await expect(chain.connect(payee).withdraw()).to.be.revertedWithCustomError(chain, "NothingToWithdraw");
    }
  }

  /** Seeds synthetic case 0 and has `submitter` submit it, so the fee is owed to it. */
  async function feeTo(submitter: TokenReentererMock) {
    const c = V.synthetic[0];
    const address = await submitter.getAddress();

    await ledger.seedCase(c, true);
    await ledger.at(c.height);
    await submitter.submit(hex(c.rawTx), c.prevouts.map(prevout), { gasLimit: SUBMIT_GAS });

    const fee = BigInt(c.fee) * ledger.unit;

    expect(fee).to.not.eq(0n);
    expect(await chain.withdrawable(address)).to.eq(fee);

    await ledger.applied(c, address);

    return fee;
  }

  before(async () => {
    [OWNER] = await ethers.getSigners();

    await reverter.snapshot();
  });

  describe("#constructor", () => {
    it("should set parameters correctly", async () => {
      await deployStandard(6, 1n);

      expect(await chain.TOKEN()).to.eq(token.target);
      expect(await chain.UNITS_PER_SAT()).to.eq(1);
      expect(await chain.GENESIS_TIME()).to.eq(GENESIS);
      expect(await chain.INTERVAL()).to.eq(INTERVAL);
      expect(await chain.DEPLOY_BLOCK()).to.eq(await ethers.provider.getBlockNumber());
    });

    it("should revert if the token has no code or no balanceOf", async () => {
      await deployStandard(6, 1n);

      const Chain = await ethers.getContractFactory("UtxoChainToken");

      for (const bad of [ethers.ZeroAddress, "0x000000000000000000000000000000000000bEEF", chain.target]) {
        await expect(Chain.deploy(2, bad, 1)).to.be.revertedWithCustomError(chain, "BadToken");
      }
    });

    it("should accept only 10^(decimals - 8) units per sat, or 1 below 8 decimals", async () => {
      await deployStandard(6, 1n);

      const Chain = await ethers.getContractFactory("UtxoChainToken");
      const cases: [number, bigint][] = [
        [0, 1n],
        [6, 1n],
        [8, 1n],
        [18, 10n ** 10n],
        [26, 10n ** 18n],
      ];

      for (const [decimals, good] of cases) {
        const t = await ethers.deployContract("ERC20Mock", [decimals]);

        expect(await (await Chain.deploy(2, t, good)).UNITS_PER_SAT()).to.eq(good);

        for (const bad of [0n, good * 10n, good == 1n ? 2n : good / 10n]) {
          await expect(Chain.deploy(2, t, bad)).to.be.revertedWithCustomError(chain, "BadUnitsPerSat");
        }
      }

      // above 10^18
      const t = await ethers.deployContract("ERC20Mock", [27]);

      await expect(Chain.deploy(2, t, 10n ** 19n)).to.be.revertedWithCustomError(chain, "BadUnitsPerSat");
    });

    it("should accept any power of ten up to 10^18 for a token without decimals", async () => {
      await deployStandard(6, 1n);

      const Chain = await ethers.getContractFactory("UtxoChainToken");
      const t = await ethers.deployContract("NoDecimalsTokenMock");

      for (const good of [1n, 1000n, 10n ** 18n]) {
        await Chain.deploy(2, t, good);
      }

      for (const bad of [0n, 3n, 1010n, 10n ** 19n]) {
        await expect(Chain.deploy(2, t, bad)).to.be.revertedWithCustomError(chain, "BadUnitsPerSat");
      }
    });

    it("should revert if the interval is zero", async () => {
      await deployStandard(6, 1n);

      const Chain = await ethers.getContractFactory("UtxoChainToken");

      await expect(Chain.deploy(0, token, 1)).to.be.revertedWithCustomError(chain, "BadInterval");
    });
  });

  describe("#deposit", () => {
    for (const [decimals, unit] of DECIMALS) {
      it(`should take exactly the amount and apply the value rules in units (${decimals} decimals)`, async () => {
        await deployStandard(decimals, unit);

        await token.mint(OWNER, (MAX_MONEY + 20_000n) * unit);

        await expect(chain.deposit(unit, P2WPKH)).to.be.revertedWithCustomError(chain, "TooEarly");

        await ledger.at(1);

        // not approved
        await expect(chain.deposit(unit, P2WPKH)).to.be.revertedWithCustomError(chain, "TokenTransferFailed");

        await token.approve(chain, ethers.MaxUint256);

        const bad = [0n, (MAX_MONEY + 1n) * unit, ...(unit > 1n ? [unit - 1n, unit + 1n] : [])];

        for (const amount of bad) {
          await expect(chain.deposit(amount, P2WPKH)).to.be.revertedWithCustomError(chain, "BadDepositValue");
        }

        await expect(chain.deposit(unit, "0x6a")).to.be.revertedWithCustomError(chain, "BadDepositScript");

        await ledger.checkInvariant();

        await deposit(unit, P2WPKH);
        await deposit(MAX_MONEY * unit, P2WPKH);
        await deposit(12_345n * unit, P2TR);

        expect(await token.balanceOf(OWNER)).to.eq(7_654n * unit);
      });

      it(`should build the deposit transactions of SPEC 3.3 byte for byte (${decimals} decimals)`, async () => {
        await deployStandard(decimals, unit);

        // The same deposit txs and txids (amounts in sats) as the ETH contract.
        await networkHelpers.setCode(V.deposits.address, await ethers.provider.getCode(chain));
        chain = chain.attach(V.deposits.address) as UtxoChainTokenMock;
        track(unit);

        await token.mint(OWNER, 10n ** 40n);
        await token.approve(chain, ethers.MaxUint256);

        await ledger.at(5);

        for (const d of V.deposits.txs) {
          const tx = chain.deposit(BigInt(d.amount) * unit, hex(d.script));

          await expect(tx).to.emit(chain, "TxApplied").withArgs(5, hex(d.txid), hex(d.rawTx));
          await expect(tx).to.changeTokenBalance(ethers, token, chain, BigInt(d.amount) * unit);

          ledger.record(d.txid, 0, BigInt(d.amount), d.script, 5);
          await ledger.checkInvariant();
        }

        await ledger.submitValid(V.deposits.spend);
        await drain();
      });
    }

    it("should not take ETH", async () => {
      await deployStandard(6, 1n);
      await ledger.at(1);

      const data = chain.interface.encodeFunctionData("deposit", [1n, P2WPKH]);

      await expect(OWNER.sendTransaction({ to: chain, data, value: 1 })).to.be.revert(ethers);
      await expect(OWNER.sendTransaction({ to: chain, value: 1 })).to.be.revert(ethers);
    });

    it("should accept a token that returns no bool", async () => {
      await deploy(1n, "NoBoolTokenMock");

      await token.mint(OWNER, 10n ** 12n);
      await token.approve(chain, ethers.MaxUint256);

      await ledger.at(1);
      await deposit(5_000n, P2WPKH);

      await ledger.submitValid(V.synthetic[V.exitCase]);
      await drain();
    });

    it("should revert if the token returns false or a malformed value", async () => {
      await deploy(1n, "FalseTokenMock");

      const falseToken = await ethers.getContractAt("FalseTokenMock", token);

      await token.mint(OWNER, 10n ** 12n);
      await token.approve(chain, ethers.MaxUint256);

      await ledger.at(1);

      for (const [failing, malformed] of [
        [true, false],
        [false, true],
      ]) {
        await falseToken.set(failing, malformed);

        await expect(chain.deposit(5_000n, P2WPKH)).to.be.revertedWithCustomError(chain, "TokenTransferFailed");
      }

      await falseToken.set(false, false);
      await deposit(5_000n, P2WPKH);
    });

    it("should revert if a transfer fee is taken from what the contract receives", async () => {
      await deploy(1n, "FeeTokenMock");

      const feeToken = await ethers.getContractAt("FeeTokenMock", token);

      await token.mint(OWNER, 10n ** 12n);
      await token.approve(chain, ethers.MaxUint256);

      await ledger.at(1);

      // 0.1% + 1 unit, out of what the contract receives
      await feeToken.setFee(10, false);

      await expect(chain.deposit(100_000n, P2WPKH)).to.be.revertedWithCustomError(chain, "TokenAmountMismatch");
      expect(await chain.depositNonce()).to.eq(0);

      // charged to the depositor on top: the contract's books stay exact
      await feeToken.setFee(10, true);

      const before = await token.balanceOf(OWNER);

      await deposit(100_000n, P2WPKH);

      expect(before - (await token.balanceOf(OWNER))).to.eq(100_000n + 101n);
    });

    for (let k = 0; k < 4; ++k) {
      const propagate = k >= 2;
      const viaDeposit = k % 2 == 0;

      it(`should refuse a depositor whose hook re-enters with a ${viaDeposit ? "deposit" : "withdraw"}${
        propagate ? " and lets the revert through" : ""
      }`, async () => {
        await deploy(10n ** 10n, "HookTokenMock");

        const reenterer = await ethers.deployContract("TokenReentererMock", [chain, propagate]);

        await reenterer.setViaDeposit(viaDeposit);
        await feeTo(reenterer);

        await token.mint(reenterer, 10n ** 20n);
        await reenterer.approve(token, ethers.MaxUint256);

        const nonce = await chain.depositNonce();

        if (!propagate) {
          const receipt = await (await reenterer.depositFrom(10n ** 10n, P2WPKH, HOOK_GAS)).wait();
          const log = chain.interface.parseLog(receipt!.logs.find((l) => l.address == chain.target)!)!;

          expect(await reenterer.innerError()).to.eq(chain.interface.encodeErrorResult("Reentrancy"));
          expect(await chain.depositNonce()).to.eq(nonce + 1n);

          ledger.record(log.args.txid.slice(2), 0, 1n, P2WPKH.slice(2), Number(log.args.height));
        } else {
          // the hook's revert fails the token's transferFrom
          await expect(reenterer.depositFrom(10n ** 10n, P2WPKH, HOOK_GAS)).to.be.revertedWithCustomError(
            chain,
            "TokenTransferFailed",
          );

          expect(await chain.depositNonce()).to.eq(nonce);
        }

        await ledger.checkInvariant();
      });
    }
  });

  describe("#submit", () => {
    for (const [decimals, unit] of DECIMALS) {
      for (const file of V.real) {
        it(`should replay ${file.file} in token units (${decimals} decimals)`, async () => {
          await deployStandard(decimals, unit);

          for (const c of file.cases) {
            await ledger.submitValid(c);
          }

          await drain();
        });
      }

      it(`should apply every synthetic transaction in token units (${decimals} decimals)`, async () => {
        for (const c of V.synthetic) {
          await deployStandard(decimals, unit);
          await ledger.submitValid(c);
          await drain();
        }
      });
    }
  });

  describe("#withdraw", () => {
    for (const [decimals, unit] of DECIMALS) {
      it(`should pay exits and fees in units (${decimals} decimals)`, async () => {
        await deployStandard(decimals, unit);

        const c = V.synthetic[V.exitCase];

        await ledger.submitValid(c);

        for (const o of c.outs.filter((o) => isExit(o.script))) {
          expect(await chain.withdrawable(ethers.getAddress(hex(o.script.slice(4))))).to.eq(BigInt(o.amount) * unit);
        }

        expect(await chain.withdrawable(OWNER)).to.eq(BigInt(c.fee) * unit);

        await drain();
      });
    }

    it("should release the lock after each token call in one transaction", async () => {
      await deployStandard(6, 1n);

      const batch = await ethers.deployContract("BatchMock");
      const c = V.synthetic[0];

      await ledger.seedCase(c, true);
      await ledger.at(c.height);
      // its fee goes to the batch contract
      await batch.submit(chain, hex(c.rawTx), c.prevouts.map(prevout), { gasLimit: SUBMIT_GAS });

      const fee = BigInt(c.fee) * ledger.unit;

      await ledger.applied(c, await batch.getAddress());

      await token.mint(batch, 6);

      const nonce = await chain.depositNonce();

      // 6 units deposited, the fee withdrawn
      await expect(batch.run(chain, token, P2WPKH)).to.changeTokenBalances(
        ethers,
        token,
        [chain, batch],
        [6n - fee, fee - 6n],
      );

      expect(await chain.depositNonce()).to.eq(nonce + 3n);
      expect(await chain.withdrawable(batch)).to.eq(0);
    });

    it("should keep the balance owed if the token returns false or a malformed value", async () => {
      await deploy(1n, "FalseTokenMock");

      const falseToken = await ethers.getContractAt("FalseTokenMock", token);

      await ledger.submitValid(V.synthetic[V.exitCase]);

      const owed = await chain.withdrawable(OWNER);

      expect(owed).to.not.eq(0n);

      for (const [failing, malformed] of [
        [true, false],
        [false, true],
      ]) {
        await falseToken.set(failing, malformed);

        await expect(chain.withdraw()).to.be.revertedWithCustomError(chain, "TokenTransferFailed");
      }

      expect(await chain.withdrawable(OWNER)).to.eq(owed);
      await ledger.checkInvariant();

      await falseToken.set(false, false);
      await drain();
    });

    it("should revert if a transfer fee is charged to the contract on top", async () => {
      await deploy(1n, "FeeTokenMock");

      const feeToken = await ethers.getContractAt("FeeTokenMock", token);

      await ledger.submitValid(V.synthetic[V.exitCase]);

      const owed = await chain.withdrawable(OWNER);

      expect(owed).to.not.eq(0n);

      await feeToken.setFee(10, true);

      await expect(chain.withdraw()).to.be.revertedWithCustomError(chain, "TokenAmountMismatch");

      expect(await chain.withdrawable(OWNER)).to.eq(owed);
      await ledger.checkInvariant();

      // out of what the withdrawer receives: theirs to pay
      await feeToken.setFee(10, false);

      await expect(chain.withdraw()).to.changeTokenBalance(ethers, token, OWNER, owed - ((owed * 10n) / 10_000n + 1n));

      ledger.owed.set(OWNER.address, 0n);
      await ledger.checkInvariant();

      await feeToken.setFee(0, false);
      await drain();
    });

    for (let k = 0; k < 4; ++k) {
      const propagate = k >= 2;
      const viaDeposit = k % 2 == 1;

      it(`should pay once a recipient whose hook re-enters with a ${viaDeposit ? "deposit" : "withdraw"}${
        propagate ? " and lets the revert through" : ""
      }`, async () => {
        await deploy(10n ** 10n, "HookTokenMock");

        const reenterer = await ethers.deployContract("TokenReentererMock", [chain, propagate]);
        const address = await reenterer.getAddress();

        await reenterer.setViaDeposit(viaDeposit);

        const fee = await feeTo(reenterer);

        if (!propagate) {
          await expect(reenterer.attack(HOOK_GAS)).to.changeTokenBalances(
            ethers,
            token,
            [chain, reenterer],
            [-fee, fee],
          );

          expect(await reenterer.calls()).to.eq(1);
          expect(await reenterer.innerError()).to.eq(
            chain.interface.encodeErrorResult(viaDeposit ? "Reentrancy" : "NothingToWithdraw"),
          );
          expect(await chain.withdrawable(address)).to.eq(0);

          ledger.owed.set(address, 0n);
        } else {
          // the hook's revert fails the token's transfer
          await expect(reenterer.attack(HOOK_GAS)).to.be.revertedWithCustomError(chain, "TokenTransferFailed");

          expect(await chain.withdrawable(address)).to.eq(fee);
        }

        await ledger.checkInvariant();
      });
    }
  });
});
