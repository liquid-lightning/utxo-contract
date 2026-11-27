import { expect } from "chai";
import hre from "hardhat";

import type { EventLog } from "ethers";

import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/types";

import {
  type AssetBadJson,
  type AssetCaseJson,
  AssetLedger,
  Reverter,
  SUBMIT_GAS,
  type VectorsV2,
  assetPrevout,
  expectCustomError,
  hex,
  readJson,
} from "@test-helpers";

import type { ERC20Mock, MultiReentererMock, MultiUtxoChainMock } from "@ethers-v6";

const { ethers, networkHelpers } = await hre.network.create();

const V = readJson<VectorsV2>("v2/vectors.json");

const SAT = 10n ** 10n;
const MAX_MONEY = 21_000_000n * 100_000_000n;
const P2WPKH = "0x0014aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const P2WSH = "0x0020aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

const FEE = V.feeAsset;
const [T6, T18] = V.tokens;

// A hook that runs out of gas is ignored by the hook token, so gas estimation
// would settle on a limit that starves it: these calls get a fixed one.
const HOOK_GAS = { gasLimit: 2_000_000n };

const Reentry = { None: 0, Withdraw: 1, DepositNative: 2, Deposit: 3 };

describe("MultiUtxoChain", () => {
  const reverter = new Reverter(networkHelpers);

  const GENESIS = BigInt(V.genesisTime);
  const INTERVAL = BigInt(V.interval);

  let OWNER: HardhatEthersSigner;
  let SECOND: HardhatEthersSigner;

  let chain: MultiUtxoChainMock;
  let token6: ERC20Mock;
  let token18: ERC20Mock;
  let ledger: AssetLedger;

  /**
   * A fresh chain whose block 0 is at GENESIS, with a 6-decimal and an
   * 18-decimal token registered. They are the first three contracts OWNER
   * deploys, so they are at the addresses the vectors were built for.
   * `six` and `eighteen` name other token mocks to put there.
   */
  async function deploy(six = "ERC20Mock", eighteen = "ERC20Mock") {
    await reverter.revert();
    await networkHelpers.time.setNextBlockTimestamp(GENESIS);

    chain = await ethers.deployContract("MultiUtxoChainMock", [INTERVAL, hex(FEE), OWNER]);
    token6 = (await ethers.deployContract(six, six == "ERC20Mock" ? [6] : [])) as unknown as ERC20Mock;
    token18 = (await ethers.deployContract(eighteen, eighteen == "ERC20Mock" ? [18] : [])) as unknown as ERC20Mock;

    expect((await chain.getAddress()).toLowerCase()).to.eq(V.deposits.address);
    expect((await token6.getAddress()).toLowerCase()).to.eq(T6.address);
    expect((await token18.getAddress()).toLowerCase()).to.eq(T18.address);

    await chain.registerToken(token6, T6.unitsPerSat);
    await chain.registerToken(token18, T18.unitsPerSat);

    const tokens = new Map([
      [T6.asset, token6],
      [T18.asset, token18],
    ]);

    ledger = new AssetLedger(
      { ethers, networkHelpers },
      chain,
      new Map([
        [FEE, SAT],
        [T6.asset, BigInt(T6.unitsPerSat)],
        [T18.asset, BigInt(T18.unitsPerSat)],
      ]),
      FEE,
      GENESIS,
      INTERVAL,
      async (asset) => (asset == FEE ? ethers.provider.getBalance(chain) : tokens.get(asset)!.balanceOf(chain)),
      async (asset, units) => {
        await tokens.get(asset)!.mint(chain, units);
      },
      OWNER.address,
    );
  }

  function tokenOf(asset: string): ERC20Mock {
    return asset == T6.asset ? token6 : token18;
  }

  /** A deposit's (height, txid) from its TxApplied event. */
  async function applied(tx: Promise<any>) {
    const receipt = await (await tx).wait();
    const log = receipt.logs.find((l: EventLog) => l.address == chain.target);
    const { height, txid } = chain.interface.parseLog(log)!.args;

    return { height: Number(height), txid: txid as string };
  }

  async function depositNative(value: bigint, script: string) {
    const { height, txid } = await applied(chain.depositNative(script, { value }));

    expect(await chain.isUnspent(txid, 0, hex(FEE), value / SAT, script, height)).to.be.true;

    ledger.record(txid.slice(2), 0, FEE, value / SAT, script.slice(2), height);
    await ledger.checkInvariant();
  }

  async function deposit(asset: string, amount: bigint, script: string) {
    const { height, txid } = await applied(chain.deposit(tokenOf(asset), amount, script));
    const sats = amount / ledger.unit(asset);

    expect(await chain.isUnspent(txid, 0, hex(asset), sats, script, height)).to.be.true;

    ledger.record(txid.slice(2), 0, asset, sats, script.slice(2), height);
    await ledger.checkInvariant();
  }

  async function impersonate(address: string) {
    await networkHelpers.impersonateAccount(address);
    await networkHelpers.setBalance(address, 10n ** 18n);

    return ethers.getSigner(address);
  }

  /** Withdraws everything owed, checking each payee gets exactly what the ledger says. */
  async function drain() {
    for (const [account, asset, amount] of ledger.owing()) {
      const payee = account == OWNER.address ? OWNER : await impersonate(account);
      const tx = chain.connect(payee).withdraw(hex(asset));

      if (asset == FEE) {
        await expect(tx).to.changeEtherBalance(ethers, account, amount);
      } else {
        await expect(tx).to.changeTokenBalance(ethers, tokenOf(asset), account, amount);
      }

      ledger.settle(account, asset);
      await ledger.checkInvariant();

      await expect(chain.connect(payee).withdraw(hex(asset))).to.be.revertedWithCustomError(chain, "NothingToWithdraw");
    }
  }

  function findCase(name: string): AssetCaseJson {
    return V.valid.find((c) => c.name == name)!;
  }

  /** Has `submitter` submit the case with a fee in every asset, so it is owed each. */
  async function feesTo(submitter: MultiReentererMock) {
    const c = findCase("a fee in every asset");
    const address = await submitter.getAddress();

    await ledger.seedCase(c, true);
    await ledger.at(c.height);
    await submitter.submit(hex(c.rawTx), c.prevouts.map(assetPrevout), { gasLimit: SUBMIT_GAS });
    await ledger.applied(c, address);

    const fees = new Map(c.outs.filter((o) => o.script == "").map((o) => [o.asset, BigInt(o.amount)]));

    return (asset: string) => fees.get(asset)! * ledger.unit(asset);
  }

  before(async () => {
    [OWNER, SECOND] = await ethers.getSigners();

    await networkHelpers.setBalance(OWNER.address, 10n ** 30n);

    await reverter.snapshot();
  });

  describe("#constructor", () => {
    it("should set parameters correctly", async () => {
      await deploy();

      expect(await chain.GENESIS_TIME()).to.eq(GENESIS);
      expect(await chain.INTERVAL()).to.eq(INTERVAL);
      expect(await chain.FEE_ASSET()).to.eq(hex(FEE));
      expect(await chain.owner()).to.eq(OWNER.address);
      expect(await chain.depositNonce()).to.eq(0);
      expect(await chain.txCount()).to.eq(0);
      expect(await chain.logHash()).to.eq(ethers.ZeroHash);
      expect(await chain.assetInfo(hex(FEE))).to.deep.eq([ethers.ZeroAddress, SAT]);
    });

    it("should revert if the interval or the fee asset is zero", async () => {
      await deploy();

      const Chain = await ethers.getContractFactory("MultiUtxoChain");

      await expect(Chain.deploy(0, hex(FEE), OWNER)).to.be.revertedWithCustomError(chain, "BadInterval");
      await expect(Chain.deploy(2, ethers.ZeroHash, OWNER)).to.be.revertedWithCustomError(chain, "BadFeeAsset");
    });
  });

  describe("#assetOf", () => {
    it("should be the token's address reversed, then 12 zero bytes", async () => {
      await deploy();

      for (const [token, t] of [
        [token6, T6],
        [token18, T18],
      ] as const) {
        const address = ethers.getBytes(await token.getAddress());

        expect(await chain.assetOf(token)).to.eq(hex(t.asset));
        expect(await chain.assetOf(token)).to.eq(ethers.zeroPadBytes(address.reverse(), 32));
      }
    });
  });

  describe("#registerToken", () => {
    it("should register a token and emit AssetRegistered", async () => {
      await deploy();

      const token = await ethers.deployContract("ERC20Mock", [8]);
      const asset = await chain.assetOf(token);

      await expect(chain.registerToken(token, 1)).to.emit(chain, "AssetRegistered").withArgs(asset, token, 1);

      expect(await chain.assetInfo(asset)).to.deep.eq([token.target, 1n]);
      expect(await chain.assetInfo(hex(T18.asset))).to.deep.eq([token18.target, 10n ** 10n]);
    });

    it("should revert if the caller is not the owner", async () => {
      await deploy();

      const token = await ethers.deployContract("ERC20Mock", [8]);

      await expect(chain.connect(SECOND).registerToken(token, 1))
        .to.be.revertedWithCustomError(chain, "OwnableUnauthorizedAccount")
        .withArgs(SECOND.address);
    });

    it("should revert if the token is already registered", async () => {
      await deploy();

      await expect(chain.registerToken(token6, 1)).to.be.revertedWithCustomError(chain, "AssetAlreadyRegistered");
    });

    it("should revert if the token has no code or no balanceOf", async () => {
      await deploy();

      for (const bad of [ethers.ZeroAddress, "0x000000000000000000000000000000000000bEEF", chain.target]) {
        await expect(chain.registerToken(bad, 1)).to.be.revertedWithCustomError(chain, "BadToken");
      }
    });

    it("should accept only 10^(decimals - 8) units per sat, or 1 below 8 decimals", async () => {
      await deploy();

      const cases: [number, bigint][] = [
        [0, 1n],
        [8, 1n],
        [12, 10n ** 4n],
        [26, 10n ** 18n],
      ];

      for (const [decimals, good] of cases) {
        const token = await ethers.deployContract("ERC20Mock", [decimals]);

        for (const bad of [0n, good * 10n, good == 1n ? 2n : good / 10n]) {
          await expect(chain.registerToken(token, bad)).to.be.revertedWithCustomError(chain, "BadUnitsPerSat");
        }

        await chain.registerToken(token, good);
      }

      // above 10^18
      const token = await ethers.deployContract("ERC20Mock", [27]);

      await expect(chain.registerToken(token, 10n ** 19n)).to.be.revertedWithCustomError(chain, "BadUnitsPerSat");
    });

    it("should accept a power of ten up to 10^18 for a token without decimals", async () => {
      await deploy();

      for (const bad of [0n, 3n, 1010n, 10n ** 19n]) {
        const token = await ethers.deployContract("NoDecimalsTokenMock");

        await expect(chain.registerToken(token, bad)).to.be.revertedWithCustomError(chain, "BadUnitsPerSat");
      }

      for (const good of [1n, 1000n, 10n ** 18n]) {
        await chain.registerToken(await ethers.deployContract("NoDecimalsTokenMock"), good);
      }
    });
  });

  describe("#depositNative", () => {
    it("should revert at height zero", async () => {
      await deploy();

      await expect(chain.depositNative(P2WPKH, { value: SAT })).to.be.revertedWithCustomError(chain, "TooEarly");

      await ledger.at(1);
      await depositNative(SAT, P2WPKH);
    });

    it("should revert if the value is not a whole number of sats within MAX_MONEY", async () => {
      await deploy();
      await ledger.at(1);

      for (const value of [0n, SAT - 1n, SAT + 1n, (MAX_MONEY + 1n) * SAT]) {
        await expect(chain.depositNative(P2WPKH, { value })).to.be.revertedWithCustomError(chain, "BadDepositValue");
      }

      await depositNative(MAX_MONEY * SAT, P2WPKH);
    });

    it("should revert if the script is empty, too long, an exit or an OP_RETURN", async () => {
      await deploy();
      await ledger.at(1);

      // an empty script would be a fee output
      const bad = [
        "0x",
        hex("51".repeat(10_001)),
        "0x60141111111111111111111111111111111111111111",
        "0x6a",
        "0x6a0401",
      ];

      for (const script of bad) {
        await expect(chain.depositNative(script, { value: SAT })).to.be.revertedWithCustomError(
          chain,
          "BadDepositScript",
        );
      }

      await depositNative(SAT, hex("51".repeat(10_000)));
      await depositNative(SAT, P2WSH);
    });
  });

  describe("#deposit", () => {
    for (const t of V.tokens) {
      it(`should take exactly the amount and apply the value rules in units (${t.decimals} decimals)`, async () => {
        await deploy();

        const token = tokenOf(t.asset);
        const unit = BigInt(t.unitsPerSat);

        await token.mint(OWNER, (MAX_MONEY + 20_000n) * unit);

        await expect(chain.deposit(token, unit, P2WPKH)).to.be.revertedWithCustomError(chain, "TooEarly");

        await ledger.at(1);

        // not approved
        await expect(chain.deposit(token, unit, P2WPKH)).to.be.revertedWithCustomError(chain, "TokenTransferFailed");

        await token.approve(chain, ethers.MaxUint256);

        for (const amount of [0n, (MAX_MONEY + 1n) * unit, ...(unit > 1n ? [unit - 1n, unit + 1n] : [])]) {
          await expect(chain.deposit(token, amount, P2WPKH)).to.be.revertedWithCustomError(chain, "BadDepositValue");
        }

        await expect(chain.deposit(token, unit, "0x")).to.be.revertedWithCustomError(chain, "BadDepositScript");

        await deposit(t.asset, unit, P2WPKH);
        await deposit(t.asset, MAX_MONEY * unit, P2WPKH);
        await deposit(t.asset, 12_345n * unit, P2WSH);

        expect(await token.balanceOf(OWNER)).to.eq(7_654n * unit);
      });
    }

    it("should revert if the token is not registered", async () => {
      await deploy();
      await ledger.at(1);

      const token = await ethers.deployContract("ERC20Mock", [6]);

      await token.mint(OWNER, 1000);
      await token.approve(chain, ethers.MaxUint256);

      await expect(chain.deposit(token, 1, P2WPKH)).to.be.revertedWithCustomError(chain, "UnknownAsset");
      await expect(chain.deposit(ethers.ZeroAddress, 1, P2WPKH)).to.be.revertedWithCustomError(chain, "UnknownAsset");
    });

    it("should build the deposit transactions byte for byte", async () => {
      await deploy();

      expect((await ethers.provider.getNetwork()).chainId).to.eq(V.deposits.chainId);

      for (const token of [token6, token18]) {
        await token.mint(OWNER, 10n ** 40n);
        await token.approve(chain, ethers.MaxUint256);
      }

      await ledger.at(5);

      for (let i = 0; i < V.deposits.txs.length; ++i) {
        const d = V.deposits.txs[i];
        const value = BigInt(d.amount) * ledger.unit(d.asset);
        const tx =
          d.token === null
            ? chain.depositNative(hex(d.script), { value })
            : chain.deposit(d.token, value, hex(d.script));

        await expect(tx).to.emit(chain, "TxApplied").withArgs(5, hex(d.txid), hex(d.rawTx));

        expect(ethers.sha256(ethers.sha256(hex(d.rawTx)))).to.eq(hex(d.txid));
        expect(await chain.isUnspent(hex(d.txid), 0, hex(d.asset), d.amount, hex(d.script), 5)).to.be.true;
        expect(await chain.depositNonce()).to.eq(i + 1);

        ledger.record(d.txid, 0, d.asset, BigInt(d.amount), d.script, 5);
        await ledger.checkInvariant();
      }

      await ledger.submitValid(V.deposits.spend);
      await drain();
    });

    it("should not take ETH", async () => {
      await deploy();
      await ledger.at(1);

      const data = chain.interface.encodeFunctionData("deposit", [token6.target, 1n, P2WPKH]);

      await expect(OWNER.sendTransaction({ to: chain, data, value: 1 })).to.be.revert(ethers);
      await expect(OWNER.sendTransaction({ to: chain, value: 1 })).to.be.revert(ethers);
    });

    it("should accept a token that returns no bool", async () => {
      await deploy("NoBoolTokenMock");

      await token6.mint(OWNER, 10n ** 12n);
      await token6.approve(chain, ethers.MaxUint256);

      await ledger.at(1);
      await deposit(T6.asset, 5_000n, P2WPKH);
    });

    it("should revert if the token returns false or a malformed value", async () => {
      await deploy("FalseTokenMock");

      const falseToken = await ethers.getContractAt("FalseTokenMock", token6);

      await token6.mint(OWNER, 10n ** 12n);
      await token6.approve(chain, ethers.MaxUint256);

      await ledger.at(1);

      for (const [failing, malformed] of [
        [true, false],
        [false, true],
      ]) {
        await falseToken.set(failing, malformed);

        await expect(chain.deposit(token6, 5_000n, P2WPKH)).to.be.revertedWithCustomError(chain, "TokenTransferFailed");
      }

      await falseToken.set(false, false);
      await deposit(T6.asset, 5_000n, P2WPKH);
    });

    it("should revert if a transfer fee is taken from what the contract receives", async () => {
      await deploy("FeeTokenMock");

      const feeToken = await ethers.getContractAt("FeeTokenMock", token6);

      await token6.mint(OWNER, 10n ** 12n);
      await token6.approve(chain, ethers.MaxUint256);

      await ledger.at(1);
      await feeToken.setFee(10, false);

      await expect(chain.deposit(token6, 100_000n, P2WPKH)).to.be.revertedWithCustomError(chain, "TokenAmountMismatch");
      expect(await chain.depositNonce()).to.eq(0);

      // charged to the depositor on top: the contract's books stay exact
      await feeToken.setFee(10, true);
      await deposit(T6.asset, 100_000n, P2WPKH);
    });

    it("should refuse a depositor whose hook re-enters", async () => {
      for (const [reentry, target] of [
        [Reentry.Deposit, null],
        [Reentry.DepositNative, null],
        [Reentry.Withdraw, FEE],
      ] as const) {
        await deploy("ERC20Mock", "HookTokenMock");

        const reenterer = await ethers.deployContract("MultiReentererMock", [chain]);

        await feesTo(reenterer);
        await networkHelpers.setBalance(reenterer.target as string, 10n ** 18n);

        await reenterer.set(reentry, target === null ? ethers.zeroPadValue(T18.address, 32) : hex(target), false);
        await token18.mint(reenterer, 10n ** 20n);
        await reenterer.approve(token18, ethers.MaxUint256);

        const nonce = await chain.depositNonce();
        const { height, txid } = await applied(reenterer.depositFrom(token18, 10n ** 10n, P2WPKH, HOOK_GAS));

        expect(await reenterer.innerError()).to.eq(chain.interface.encodeErrorResult("Reentrancy"));
        expect(await chain.depositNonce()).to.eq(nonce + 1n);

        ledger.record(txid.slice(2), 0, T18.asset, 1n, P2WPKH.slice(2), height);
        await ledger.checkInvariant();
      }
    });
  });

  describe("#submit", () => {
    it("should revert at height zero", async () => {
      await deploy();

      const c = V.valid[0];

      await expect(chain.submit(hex(c.rawTx), c.prevouts.map(assetPrevout))).to.be.revertedWithCustomError(
        chain,
        "TooEarly",
      );
    });

    for (const channel of V.channels) {
      it(`should apply every transaction of a ${channel.name}, then pay out`, async () => {
        await deploy();

        for (const c of channel.cases) {
          await ledger.submitValid(c);
        }

        await drain();
      });
    }

    for (const c of V.valid) {
      it(`should apply: ${c.name}`, async () => {
        await deploy();
        await ledger.submitValid(c);
        await drain();
      });
    }

    const badByError = new Map<string, AssetBadJson[]>();

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
              chain.submit(hex(b.rawTx), b.prevouts.map(assetPrevout), { gasLimit: SUBMIT_GAS }),
              chain,
              b.err,
            );
          } catch (e) {
            throw new Error(`${b.name}: ${(e as Error).message}`);
          }
        }
      });
    }

    it("should keep assets apart when one token fails", async () => {
      await deploy("FalseTokenMock");

      const falseToken = await ethers.getContractAt("FalseTokenMock", token6);

      // a channel in the failing token, one in the other token and one in
      // ETH, side by side: their transactions in the order of their heights
      const cases = V.channels.flatMap((channel) => channel.cases).sort((a, b) => a.height - b.height);

      for (const c of cases) {
        await ledger.submitValid(c);
      }

      await falseToken.set(true, false);

      for (const [account, asset] of ledger.owing()) {
        const payee = account == OWNER.address ? OWNER : await impersonate(account);
        const tx = chain.connect(payee).withdraw(hex(asset));

        if (asset == T6.asset) {
          await expect(tx).to.be.revertedWithCustomError(chain, "TokenTransferFailed");
        } else {
          await tx;
          ledger.settle(account, asset);
        }
      }

      await ledger.checkInvariant();

      await falseToken.set(false, false);
      await drain();
    });
  });

  describe("#withdraw", () => {
    it("should pay each asset once, to whom it is owed", async () => {
      await deploy();

      const c = findCase("a fee in every asset");

      await ledger.submitValid(c);

      expect(await chain.withdrawable(OWNER, hex(FEE))).to.eq(300n * SAT);
      expect(await chain.withdrawable(OWNER, hex(T6.asset))).to.eq(10n);
      expect(await chain.withdrawable(OWNER, hex(T18.asset))).to.eq(20n * 10n ** 10n);
      expect(await chain.withdrawable(SECOND, hex(FEE))).to.eq(0);

      await expect(chain.connect(SECOND).withdraw(hex(FEE))).to.be.revertedWithCustomError(chain, "NothingToWithdraw");
      await expect(chain.withdraw(ethers.id("no such asset"))).to.be.revertedWithCustomError(
        chain,
        "NothingToWithdraw",
      );

      await drain();
    });

    it("should refuse a recipient of ETH that re-enters", async () => {
      for (const [reentry, target] of [
        [Reentry.Withdraw, T6.asset],
        [Reentry.DepositNative, FEE],
      ] as const) {
        await deploy();

        const reenterer = await ethers.deployContract("MultiReentererMock", [chain]);
        const address = await reenterer.getAddress();
        const fee = await feesTo(reenterer);

        await reenterer.set(reentry, hex(target), false);

        await expect(reenterer.withdraw(hex(FEE), HOOK_GAS)).to.changeEtherBalances(
          ethers,
          [chain, reenterer],
          [-fee(FEE), fee(FEE)],
        );

        expect(await reenterer.calls()).to.eq(1);
        expect(await reenterer.innerError()).to.eq(chain.interface.encodeErrorResult("Reentrancy"));
        // the other asset is still owed, and still there
        expect(await chain.withdrawable(address, hex(T6.asset))).to.eq(fee(T6.asset));

        ledger.settle(address, FEE);
        await ledger.checkInvariant();
      }
    });

    it("should revert if the recipient of ETH reverts, and keep its balance", async () => {
      await deploy();

      const reenterer = await ethers.deployContract("MultiReentererMock", [chain]);
      const fee = await feesTo(reenterer);

      await reenterer.set(Reentry.Withdraw, hex(T6.asset), true);

      await expect(reenterer.withdraw(hex(FEE), HOOK_GAS)).to.be.revertedWithCustomError(chain, "WithdrawFailed");

      expect(await chain.withdrawable(reenterer, hex(FEE))).to.eq(fee(FEE));
      await ledger.checkInvariant();
    });

    it("should refuse a recipient whose token hook re-enters", async () => {
      for (const propagate of [false, true]) {
        await deploy("ERC20Mock", "HookTokenMock");

        const reenterer = await ethers.deployContract("MultiReentererMock", [chain]);
        const address = await reenterer.getAddress();
        const fee = await feesTo(reenterer);

        await reenterer.set(Reentry.Withdraw, hex(FEE), propagate);

        const tx = reenterer.withdraw(hex(T18.asset), HOOK_GAS);

        if (!propagate) {
          await expect(tx).to.changeTokenBalances(
            ethers,
            token18,
            [chain, reenterer],
            [-fee(T18.asset), fee(T18.asset)],
          );

          expect(await reenterer.innerError()).to.eq(chain.interface.encodeErrorResult("Reentrancy"));
          expect(await chain.withdrawable(address, hex(FEE))).to.eq(fee(FEE));

          ledger.settle(address, T18.asset);
        } else {
          // the hook's revert fails the token's transfer
          await expect(tx).to.be.revertedWithCustomError(chain, "TokenTransferFailed");

          expect(await chain.withdrawable(address, hex(T18.asset))).to.eq(fee(T18.asset));
        }

        await ledger.checkInvariant();
      }
    });

    it("should revert if a transfer fee is charged to the contract on top", async () => {
      await deploy("FeeTokenMock");

      const feeToken = await ethers.getContractAt("FeeTokenMock", token6);

      await ledger.submitValid(findCase("fee in a token"));

      const owed = await chain.withdrawable(OWNER, hex(T6.asset));

      expect(owed).to.eq(10n);

      await feeToken.setFee(10, true);

      await expect(chain.withdraw(hex(T6.asset))).to.be.revertedWithCustomError(chain, "TokenAmountMismatch");
      expect(await chain.withdrawable(OWNER, hex(T6.asset))).to.eq(owed);

      await feeToken.setFee(0, false);
      await drain();
    });
  });

  describe("#logHash", () => {
    it("should chain every deposit and transaction", async () => {
      await deploy();

      let count = 0n;
      let hash = ethers.ZeroHash;

      const expectLog = async (height: number, txid: string) => {
        count += 1n;
        hash = ethers.solidityPackedKeccak256(["bytes32", "uint32", "bytes32"], [hash, height, txid]);

        expect(await chain.txCount()).to.eq(count);
        expect(await chain.logHash()).to.eq(hash);
      };

      const cases = V.channels[0].cases;

      for (let i = 0; i < cases.length; ++i) {
        const c = cases[i];

        // a deposit before each transaction; a rejected (early) submit changes neither
        await ledger.at(c.height);

        const d = await applied(chain.depositNative(P2WPKH, { value: SAT * BigInt(i + 1) }));

        ledger.record(d.txid.slice(2), 0, FEE, BigInt(i + 1), P2WPKH.slice(2), d.height);
        await expectLog(d.height, d.txid);

        await ledger.submitValid(c);
        await expectLog(c.height, hex(c.txid));
      }
    });
  });
});
