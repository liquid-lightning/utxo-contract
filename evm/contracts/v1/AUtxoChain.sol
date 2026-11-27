// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BtcTx, TxView, Prevout} from "../libs/bitcoin/BtcTx.sol";
import {Validation} from "../libs/bitcoin/Validation.sol";
import {IUtxoChainBase} from "../interfaces/v1/IUtxoChainBase.sol";
import {
    TooEarly,
    BadInterval,
    HeightOverflow,
    BadDepositValue,
    BadDepositScript,
    NothingToWithdraw,
    DuplicateInput,
    UnknownUtxo
} from "../libs/utils/Errors.sol";

/// @title A Bitcoin-style UTXO set, spent by Bitcoin transactions (SPEC 4).
/// The asset is left to the two deployables (SPEC 9): `UtxoChain` holds ETH
/// (1 sat = 10^10 wei) and `UtxoChainToken` one ERC-20 (1 sat = UNITS_PER_SAT
/// token units). Here, every amount the contract holds or owes is in `UNIT`s,
/// the asset's smallest units per sat. Heights follow the wall clock:
/// H(t) = (t - GENESIS_TIME) / INTERVAL.
///
/// Errors (Errors.sol): TooEarly, BadInterval, HeightOverflow, BadDepositValue,
/// BadDepositScript, NothingToWithdraw, WithdrawFailed; in token mode BadToken,
/// BadUnitsPerSat, TokenTransferFailed, TokenAmountMismatch, Reentrancy; and
/// for `submit` TxTooLarge, Truncated, NonCanonicalCompactSize, BadSegwitFlag,
/// EmptyWitnesses, NoInputs, NoOutputs, TrailingBytes, PrevoutCountMismatch,
/// ScriptSigNotEmpty, NullPrevout, DuplicateInput, UnknownUtxo,
/// AmountTooLarge, OutputsExceedInputs, TooManySigops, NonFinal,
/// TimeRelativeLockUnsupported, RelativeLockNotMet, UnsupportedScriptPubKey,
/// BadWitness, KeyHashMismatch, WitnessScriptMismatch, UnknownWitnessScript,
/// BadPreimage, CsvNotMet, CltvNotMet, BadSignatureEncoding, BadSignature,
/// BadPublicKey, NoMatchingOutput.
///
/// Invariant (SPEC 4.1): the asset balance held >= the sum of all UTXO
/// amounts * UNIT + the sum of `withdrawable`. A deposit adds its value to
/// both sides (`_collect` checks it arrived in full); a submit moves value
/// from spent UTXOs to new UTXOs, exits and the fee (inputs >= outputs + fee
/// exactly, OP_RETURN amounts leaving the right-hand side); a withdraw lowers
/// both by the same amount (`_pay`).
abstract contract AUtxoChain is IUtxoChainBase {
    uint256 internal constant MAX_DEPOSIT_SCRIPT = 10_000;

    uint256 public immutable override GENESIS_TIME;
    uint256 public immutable override INTERVAL;
    uint256 public immutable override DEPLOY_BLOCK;

    /// keccak256(txid, uint32 vout) => keccak256(uint64 amount, scriptPubKey,
    /// uint32 height); zero when there is no such unspent output.
    mapping(bytes32 key => bytes32 commitment) public override utxo;
    /// Exits and fees, in UNITs (wei, or token units), pulled with `withdraw`.
    mapping(address account => uint256 amount) public override withdrawable;
    uint256 public override depositNonce;
    /// The number of TxApplied events emitted so far, and a hash chain over
    /// them: logHash = keccak256(logHash, uint32 height, txid) per event, in
    /// order (SPEC 4.1). Read at a block (EIP-1898), they let an index prove
    /// it has every log up to that block.
    uint64 public override txCount;
    bytes32 public override logHash;

    /// @param interval_ seconds per virtual block (2 on anvil, 60 on Base Sepolia)
    constructor(uint256 interval_) {
        if (interval_ == 0) revert BadInterval();
        GENESIS_TIME = block.timestamp;
        INTERVAL = interval_;
        DEPLOY_BLOCK = block.number;
    }

    // ------------------------------------------------------------ the asset

    /// The asset's smallest units per sat (UNIT): 10^10 wei, or the token's.
    function _unit() internal view virtual returns (uint256);

    /// Takes `value` UNITs from the depositor, or checks they came with the
    /// call; reverts unless exactly `value` arrived. Called after a deposit's
    /// checks and before its effects.
    function _collect(uint256 value_) internal virtual;

    /// Pays `amount` UNITs to `to`; reverts on any failure.
    function _pay(address to_, uint256 amount_) internal virtual;

    // ------------------------------------------------------------ SPEC 4.2

    /// Creates one output of value / UNIT sats paying `scriptPubKey`, as the
    /// output 0 of a synthetic deposit tx (SPEC 3.3).
    function _deposit(
        uint256 value_,
        bytes calldata scriptPubKey_
    ) internal returns (bytes32 txid_) {
        uint32 h_ = _applyHeight();
        uint256 unit_ = _unit();
        if (value_ % unit_ != 0 || value_ < unit_ || value_ / unit_ > Validation.MAX_MONEY) {
            revert BadDepositValue();
        }
        if (
            scriptPubKey_.length > MAX_DEPOSIT_SCRIPT ||
            _isExit(scriptPubKey_) ||
            _isOpReturn(scriptPubKey_)
        ) {
            revert BadDepositScript();
        }
        _collect(value_);
        uint64 amount_ = uint64(value_ / unit_);
        // A prevout that is never in the UTXO set (so the tx cannot be
        // replayed) and is not the null prevout (so it is not a coinbase).
        bytes32 prev_ = keccak256(
            abi.encodePacked("evmchan deposit", block.chainid, address(this), depositNonce)
        );
        // version 2, 1 input (prev:0, empty scriptSig, sequence 0xffffffff),
        // 1 output, locktime 0; no witness
        bytes memory rawTx_ = abi.encodePacked(
            hex"0200000001",
            prev_,
            hex"0000000000ffffffff01",
            BtcTx.le64(amount_),
            BtcTx.compactSizeBytes(scriptPubKey_.length),
            scriptPubKey_,
            hex"00000000"
        );
        txid_ = sha256(abi.encodePacked(sha256(rawTx_)));
        depositNonce += 1;
        utxo[utxoKey(txid_, 0)] = _commitment(amount_, scriptPubKey_, h_);
        _chainLog(h_, txid_);
        emit TxApplied(h_, txid_, rawTx_);
    }

    /// @notice Validates `rawTx` against `prevouts` at the current height
    /// (SPEC 4.3) and applies it (SPEC 4.4). Anyone may submit any valid tx;
    /// the fee goes to the submitter.
    function submit(
        bytes calldata rawTx_,
        Prevout[] calldata prevouts_
    ) external override returns (bytes32 txid_) {
        uint32 h_ = _applyHeight();
        TxView memory t_ = Validation.parse(rawTx_, prevouts_);
        // The UTXO set first: a wrong or spent prevout fails before any
        // signature is checked. The call reverts as a whole on any failure.
        _spendInputs(rawTx_, t_, prevouts_);
        uint256 fee_ = Validation.check(rawTx_, t_, prevouts_, h_, _mtp(h_));
        txid_ = t_.txid;
        _createOutputs(rawTx_, t_, h_);
        if (fee_ != 0) withdrawable[msg.sender] += fee_ * _unit();
        _chainLog(h_, txid_);
        emit TxApplied(h_, txid_, rawTx_);
    }

    /// @notice Pays msg.sender its `withdrawable` (checks-effects-interactions:
    /// the balance is zeroed before the payment).
    function withdraw() external override {
        uint256 amount_ = withdrawable[msg.sender];
        if (amount_ == 0) revert NothingToWithdraw();
        withdrawable[msg.sender] = 0;
        _pay(msg.sender, amount_);
    }

    /// @notice H(block.timestamp).
    function height() external view override returns (uint32) {
        return _height();
    }

    function isUnspent(
        bytes32 txid_,
        uint32 vout_,
        uint64 amount_,
        bytes calldata scriptPubKey_,
        uint32 height_
    ) external view override returns (bool) {
        return utxo[utxoKey(txid_, vout_)] == _commitment(amount_, scriptPubKey_, height_);
    }

    function utxoKey(bytes32 txid_, uint32 vout_) public pure override returns (bytes32) {
        return keccak256(abi.encodePacked(txid_, vout_));
    }

    // ------------------------------------------------------------ SPEC 4.4

    /// Deletes each input's UTXO, after checking it is the prevout's
    /// commitment (SPEC 4.3.2). Deleting as we go also rejects an outpoint
    /// spent twice in the tx: its second occurrence finds no UTXO. That is
    /// O(n), and the whole call reverts on any failure.
    function _spendInputs(bytes calldata raw_, TxView memory t_, Prevout[] calldata pv_) internal {
        for (uint256 i; i < t_.nIn; ++i) {
            bytes32 txid_ = BtcTx.prevTxid(raw_, t_, i);
            uint32 vout_ = BtcTx.prevVout(raw_, t_, i);
            bytes32 key_ = utxoKey(txid_, vout_);
            if (utxo[key_] != _commitment(pv_[i].amount, pv_[i].scriptPubKey, pv_[i].height)) {
                for (uint256 j; j < i; ++j) {
                    if (
                        BtcTx.prevTxid(raw_, t_, j) == txid_ &&
                        BtcTx.prevVout(raw_, t_, j) == vout_
                    ) {
                        revert DuplicateInput(i);
                    }
                }
                revert UnknownUtxo(i);
            }
            delete utxo[key_];
        }
    }

    /// Stores each output, except exits (credited to `withdrawable`) and
    /// OP_RETURN outputs (whose amounts are burned).
    /// @dev An output's key cannot already be in use: txids are unique, since a
    /// tx spends at least one UTXO, which no other valid tx can spend again,
    /// and a deposit's txid commits to a fresh nonce.
    function _createOutputs(bytes calldata raw_, TxView memory t_, uint32 h_) internal {
        uint256 n_ = BtcTx.nOut(t_);
        for (uint256 j; j < n_; ++j) {
            uint64 amount_ = BtcTx.outAmount(raw_, t_, j);
            bytes calldata spk_ = BtcTx.outScript(raw_, t_, j);
            if (_isExit(spk_)) {
                withdrawable[address(bytes20(spk_[2:22]))] += amount_ * _unit();
            } else if (!_isOpReturn(spk_)) {
                utxo[utxoKey(t_.txid, uint32(j))] = _commitment(amount_, spk_, h_);
            }
        }
    }

    // ------------------------------------------------------------ helpers

    /// SPEC 4.1/4.4: count the event and extend the log hash, just before
    /// every TxApplied.
    function _chainLog(uint32 h_, bytes32 txid_) internal {
        txCount += 1;
        logHash = keccak256(abi.encodePacked(logHash, h_, txid_));
    }

    function _commitment(
        uint64 amount_,
        bytes calldata scriptPubKey_,
        uint32 h_
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(amount_, scriptPubKey_, h_));
    }

    /// Segwit v16 with a 20-byte program: `6014<20 bytes>` (SPEC 4.4).
    function _isExit(bytes calldata spk_) internal pure returns (bool) {
        return spk_.length == 22 && spk_[0] == 0x60 && spk_[1] == 0x14;
    }

    function _isOpReturn(bytes calldata spk_) internal pure returns (bool) {
        return spk_.length != 0 && spk_[0] == 0x6a;
    }

    function _height() internal view returns (uint32) {
        uint256 h_ = (block.timestamp - GENESIS_TIME) / INTERVAL;
        if (h_ > type(uint32).max) revert HeightOverflow();
        return uint32(h_);
    }

    /// The height a deposit or submit applies at; nothing is applied at 0.
    function _applyHeight() internal view returns (uint32 h_) {
        h_ = _height();
        if (h_ == 0) revert TooEarly();
    }

    /// MTP(h) = T(max(h - 6, 0)), as SPEC 4.3.5 defines it. From h = 11 on it
    /// is the median of the 11 block times before h (they increase by
    /// INTERVAL); below that it is lower than Bitcoin's median of the blocks
    /// there are, so time locks there are met later, never earlier.
    function _mtp(uint32 h_) internal view returns (uint256) {
        return GENESIS_TIME + (h_ > 6 ? uint256(h_) - 6 : 0) * INTERVAL;
    }
}
