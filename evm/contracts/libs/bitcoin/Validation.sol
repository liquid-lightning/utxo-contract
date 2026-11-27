// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BtcTx, TxView, Stack, Prevout} from "./BtcTx.sol";
import {Bip143} from "./Bip143.sol";
import {Templates} from "./Templates.sol";
import {
    PrevoutCountMismatch,
    NullPrevout,
    AmountTooLarge,
    OutputsExceedInputs,
    TooManySigops,
    NonFinal,
    TimeRelativeLockUnsupported,
    RelativeLockNotMet,
    UnsupportedScriptPubKey
} from "../utils/Errors.sol";

/// @title SPEC 4.3: whether a tx is valid at height h against the prevouts
/// its submitter claims, except for what needs the UTXO set (each prevout's
/// commitment in it, and no outpoint spent twice), which UtxoChain checks as
/// it spends the inputs, between `parse` and `check`.
library Validation {
    uint64 internal constant MAX_MONEY = 21_000_000 * 100_000_000;
    uint256 internal constant MAX_SIGOPS_COST = 16_000;
    /// SPEC 4.3.4 counts each input at 4: no template path has more
    /// (GetSigOpCount(true) of an HTLC script: CHECKSIG, 2 for the 2-of-2
    /// CHECKMULTISIG, CHECKSIG).
    uint256 internal constant SIGOPS_PER_INPUT = 4;
    uint32 internal constant LOCKTIME_THRESHOLD = 500_000_000;

    /// @param h_ the height the tx would be applied at
    /// @param mtp_ MTP(h) = T(max(h - 6, 0)), the median time past of block h
    /// @return t_ the parsed tx
    /// @return fee_ the sum of the inputs minus the sum of the outputs, in sats
    function validate(
        bytes calldata raw_,
        Prevout[] calldata pv_,
        uint256 h_,
        uint256 mtp_
    ) internal view returns (TxView memory t_, uint256 fee_) {
        t_ = parse(raw_, pv_);
        fee_ = check(raw_, t_, pv_, h_, mtp_);
    }

    /// 4.3.1, and 4.3.2's empty scriptSigs and prevout count.
    function parse(
        bytes calldata raw_,
        Prevout[] calldata pv_
    ) internal pure returns (TxView memory t_) {
        t_ = BtcTx.parse(raw_);
        if (pv_.length != t_.nIn) revert PrevoutCountMismatch();
    }

    /// The rest of 4.3, for a tx from `parse`.
    function check(
        bytes calldata raw_,
        TxView memory t_,
        Prevout[] calldata pv_,
        uint256 h_,
        uint256 mtp_
    ) internal view returns (uint256 fee_) {
        _checkNullPrevouts(raw_, t_);
        fee_ = _checkAmounts(raw_, t_, pv_);
        _checkSigops(raw_, t_);
        checkLockTime(raw_, t_, h_, mtp_);
        _checkRelativeLocks(raw_, t_, pv_, h_);
        _checkScripts(raw_, t_, pv_);
    }

    /// 4.3.2: no input spends the null prevout (32 zero bytes, index 0xffffffff).
    function _checkNullPrevouts(bytes calldata raw_, TxView memory t_) private pure {
        for (uint256 i; i < t_.nIn; ++i) {
            if (
                BtcTx.prevTxid(raw_, t_, i) == 0 && BtcTx.prevVout(raw_, t_, i) == type(uint32).max
            ) revert NullPrevout(i);
        }
    }

    /// 4.3.3: every amount, and each sum, at most MAX_MONEY; inputs >= outputs.
    function _checkAmounts(
        bytes calldata raw_,
        TxView memory t_,
        Prevout[] calldata pv_
    ) private pure returns (uint256) {
        uint256 total_;
        for (uint256 i; i < pv_.length; ++i) {
            uint64 a_ = pv_[i].amount;
            if (a_ > MAX_MONEY) revert AmountTooLarge();
            total_ += a_;
        }
        uint256 out_;
        uint256 n_ = BtcTx.nOut(t_);
        for (uint256 j; j < n_; ++j) {
            uint64 a_ = BtcTx.outAmount(raw_, t_, j);
            if (a_ > MAX_MONEY) revert AmountTooLarge();
            out_ += a_;
        }
        if (total_ > MAX_MONEY || out_ > MAX_MONEY) revert AmountTooLarge();
        if (out_ > total_) revert OutputsExceedInputs();
        return total_ - out_;
    }

    /// 4.3.4: 4 * (legacy sigops in all output scripts) + 4 * (input count) <= 16,000.
    function _checkSigops(bytes calldata raw_, TxView memory t_) private pure {
        uint256 legacy_;
        uint256 n_ = BtcTx.nOut(t_);
        for (uint256 j; j < n_; ++j) {
            legacy_ += legacySigops(BtcTx.outScript(raw_, t_, j));
        }
        if (4 * legacy_ + SIGOPS_PER_INPUT * t_.nIn > MAX_SIGOPS_COST) revert TooManySigops();
    }

    /// Bitcoin's GetSigOpCount(false): CHECKSIG(VERIFY) 1, CHECKMULTISIG(VERIFY)
    /// 20, pushed data skipped, and the count stops at a push that runs past
    /// the end of the script (GetOp fails).
    function legacySigops(bytes calldata s_) internal pure returns (uint256 n_) {
        assembly ("memory-safe") {
            let p := s_.offset
            let end := add(p, s_.length)
            for {} lt(p, end) {} {
                let op := byte(0, calldataload(p))
                p := add(p, 1)
                if iszero(op) {
                    continue
                } // OP_0
                if gt(op, 0x4e) {
                    // not a push: CHECKSIG(VERIFY) 0xac/0xad count 1,
                    // CHECKMULTISIG(VERIFY) 0xae/0xaf count 20
                    if and(gt(op, 0xab), lt(op, 0xb0)) {
                        n_ := add(n_, sub(20, mul(19, lt(op, 0xae))))
                    }
                    continue
                }
                {
                    // a push: 0x01-0x4b push that many bytes; PUSHDATA1/2/4
                    // (0x4c-0x4e) give the size in 1, 2 or 4 bytes LE
                    let size := op
                    if gt(op, 0x4b) {
                        let k := 1
                        if eq(op, 0x4d) {
                            k := 2
                        }
                        if eq(op, 0x4e) {
                            k := 4
                        }
                        if gt(add(p, k), end) {
                            break
                        }
                        let w := calldataload(p)
                        size := 0
                        for {
                            let j := 0
                        } lt(j, k) {
                            j := add(j, 1)
                        } {
                            size := or(size, shl(mul(8, j), byte(j, w)))
                        }
                        p := add(p, k)
                    }
                    if gt(size, sub(end, p)) {
                        break
                    }
                    p := add(p, size)
                }
            }
        }
    }

    /// 4.3.5 (BIP113): final if every sequence is 0xffffffff, or nLockTime is a
    /// height below h, or a time below MTP(h).
    function checkLockTime(
        bytes calldata raw_,
        TxView memory t_,
        uint256 h_,
        uint256 mtp_
    ) internal pure {
        uint32 lt_ = t_.locktime;
        if (lt_ < LOCKTIME_THRESHOLD ? lt_ < h_ : lt_ < mtp_) return;
        for (uint256 i; i < t_.nIn; ++i) {
            if (BtcTx.sequence(raw_, t_, i) != Templates.SEQUENCE_FINAL) revert NonFinal();
        }
    }

    /// 4.3.6 (BIP68), for version >= 2: an input whose sequence has bit 31
    /// clear is a time lock (unsupported) if bit 22 is set, and otherwise needs
    /// h - prevout.height >= sequence & 0xffff.
    function _checkRelativeLocks(
        bytes calldata raw_,
        TxView memory t_,
        Prevout[] calldata pv_,
        uint256 h_
    ) private pure {
        if (t_.version < 2) return;
        for (uint256 i; i < t_.nIn; ++i) {
            uint32 seq_ = BtcTx.sequence(raw_, t_, i);
            if (seq_ & Templates.SEQ_DISABLE != 0) continue;
            if (seq_ & Templates.SEQ_TYPE != 0) revert TimeRelativeLockUnsupported(i);
            if (h_ < uint256(pv_[i].height) + (seq_ & Templates.SEQ_MASK))
                revert RelativeLockNotMet(i);
        }
    }

    /// 4.3.7: each input's scriptPubKey is P2WPKH, P2TR or P2WSH, and its
    /// witness satisfies it.
    function _checkScripts(
        bytes calldata raw_,
        TxView memory t_,
        Prevout[] calldata pv_
    ) private view {
        for (uint256 i; i < t_.nIn; ++i) {
            // Nothing allocated while checking one input is used afterwards
            // (the lazily computed hashes are stored in t's own fields), so
            // the memory is reused for the next input: without this, a tx
            // with hundreds of inputs pays quadratic memory gas.
            uint256 freeMem_;
            assembly {
                freeMem_ := mload(0x40)
            }
            bytes calldata spk_ = pv_[i].scriptPubKey;
            Stack memory w_ = BtcTx.stack(raw_, t_, i);
            if (spk_.length == 22 && spk_[0] == 0x00 && spk_[1] == 0x14) {
                Templates.p2wpkh(
                    raw_,
                    t_,
                    Templates.Input(i, pv_[i].amount, w_, Bip143.sigHash),
                    bytes20(spk_[2:22])
                );
            } else if (spk_.length == 34 && spk_[0] == 0x00 && spk_[1] == 0x20) {
                Templates.p2wsh(
                    raw_,
                    t_,
                    Templates.Input(i, pv_[i].amount, w_, Bip143.sigHash),
                    bytes32(spk_[2:34])
                );
            } else if (spk_.length == 34 && spk_[0] == 0x51 && spk_[1] == 0x20) {
                Templates.p2tr(raw_, t_, pv_, i, bytes32(spk_[2:34]), w_);
            } else {
                revert UnsupportedScriptPubKey(i);
            }
            assembly {
                mstore(0x40, freeMem_)
            }
        }
    }
}
