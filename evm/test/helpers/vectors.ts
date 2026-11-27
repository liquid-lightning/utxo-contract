import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export interface PrevoutJson {
  /** A string when it is too large for a double. */
  amount: number | string;
  script: string;
  height: number;
}

export interface ErrJson {
  name: string;
  /** Numbers, or a bytes32 as hex without its prefix. */
  args: (number | string)[];
}

/** A valid transaction, with what the tests check after submitting it. */
export interface CaseJson {
  name: string;
  kind: string;
  rawTx: string;
  prevouts: PrevoutJson[];
  inTxids: string[];
  inVouts: number[];
  /** Whether the test puts the prevout in the UTXO set (else an earlier case created it). */
  seed: boolean[];
  height: number;
  /** The lowest height its lock time and BIP68 locks allow. */
  minHeight: number;
  /** The revert at minHeight - 1 (null when minHeight < 2). */
  earlyError: ErrJson | null;
  txid: string;
  fee: number;
  outs: { amount: number; script: string }[];
}

/** A transaction the contract must reject with `err` at `height`, after seeding `seeds`. */
export interface BadJson {
  name: string;
  rawTx: string;
  prevouts: PrevoutJson[];
  seeds: (PrevoutJson & { txid: string; vout: number })[];
  height: number;
  err: ErrJson;
}

export interface VectorsV1 {
  genesisTime: number;
  interval: number;
  real: { file: string; cases: CaseJson[] }[];
  synthetic: CaseJson[];
  exitCase: number;
  bad: BadJson[];
  worstCase: CaseJson;
  deposits: {
    chainId: number;
    address: string;
    txs: { amount: number; script: string; rawTx: string; txid: string }[];
    spend: CaseJson;
  };
}

export function dataPath(relative: string): string {
  return fileURLToPath(new URL(`../data/${relative}`, import.meta.url));
}

/**
 * JSON.parse, with the integers a double can't hold (amounts up to 2^64 - 1,
 * values in wei, nonces) kept exact, as strings: pass them to BigInt().
 */
function parse<T>(text: string): T {
  return JSON.parse(text.replace(/("(?:amount|fee|value_wei|nonce)":\s*)(\d{16,})/g, '$1"$2"')) as T;
}

export function readJson<T>(relative: string): T {
  return parse<T>(readFileSync(dataPath(relative), "utf8"));
}

/** The lines of a JSON-lines file under test/data, or null when it is not there. */
export function readJsonLines<T>(relative: string): T[] | null {
  const path = dataPath(relative);

  if (!existsSync(path)) {
    return null;
  }

  return readFileSync(path, "utf8")
    .split("\n")
    .filter((line) => line.length != 0)
    .map((line) => parse<T>(line));
}

export const hex = (data: string): string => "0x" + data;

/** A prevout as the contract's `Prevout` struct. */
export function prevout(p: PrevoutJson) {
  return { amount: BigInt(p.amount), scriptPubKey: hex(p.script), height: p.height };
}

export function isExit(script: string): boolean {
  return script.length == 44 && script.startsWith("6014");
}

export function isOpReturn(script: string): boolean {
  return script.startsWith("6a");
}

// ------------------------------------------------------------ v2 (Elements format)

export interface AssetPrevoutJson extends PrevoutJson {
  /** The asset tag as serialized, in hex. */
  asset: string;
}

export interface AssetCaseJson extends Omit<CaseJson, "prevouts" | "outs" | "fee"> {
  prevouts: AssetPrevoutJson[];
  /** An output with an empty script is a fee. */
  outs: { asset: string; amount: number; script: string }[];
}

export interface AssetBadJson extends Omit<BadJson, "prevouts" | "seeds"> {
  prevouts: AssetPrevoutJson[];
  seeds: (AssetPrevoutJson & { txid: string; vout: number })[];
}

export interface VectorsV2 {
  genesisTime: number;
  interval: number;
  feeAsset: string;
  tokens: { address: string; asset: string; decimals: number; unitsPerSat: string }[];
  /** The transactions of an asset channel's life, in the order applied. */
  channels: { name: string; asset: string; cases: AssetCaseJson[] }[];
  /** Standalone valid cases, each for a fresh chain. */
  valid: AssetCaseJson[];
  bad: AssetBadJson[];
  deposits: {
    chainId: number;
    address: string;
    txs: { token: string | null; asset: string; amount: number; script: string; rawTx: string; txid: string }[];
    spend: AssetCaseJson;
  };
}

/** A prevout as the contract's `AssetPrevout` struct. */
export function assetPrevout(p: AssetPrevoutJson) {
  return { asset: hex(p.asset), amount: BigInt(p.amount), scriptPubKey: hex(p.script), height: p.height };
}
