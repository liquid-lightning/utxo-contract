// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BtcTx, TxView, Stack, Prevout} from "./BtcTx.sol";
import {Bip143} from "./Bip143.sol";
import {TaprootSighash} from "./TaprootSighash.sol";
import {Ecdsa} from "../crypto/Ecdsa.sol";
import {Schnorr} from "../crypto/Schnorr.sol";
import {
    BadWitness,
    KeyHashMismatch,
    WitnessScriptMismatch,
    UnknownWitnessScript,
    BadPreimage,
    CsvNotMet,
    CltvNotMet,
    BadSignatureEncoding,
    BadSignature,
    BadPublicKey,
    NoMatchingOutput
} from "../utils/Errors.sol";

/// @title The scriptPubKeys the contract can spend (SPEC 4.3.7): P2WPKH, P2TR
/// key path, and P2WSH with the scripts Core Lightning builds for the anchors
/// channel type, recognised by exact bytes (bitcoin/script.c).
///
/// @notice Each P2WSH check is the Script semantics of its template, with the
/// witness stack as Script would see it: the stack size and the form of each
/// item are exactly those of SPEC 4.3.7's table (CLEANSTACK is consensus for
/// segwit), the path is chosen by the same data Script uses, and every
/// opcode's condition is enforced (CHECKSIG/CHECKMULTISIG via BIP143 and
/// ECDSA, HASH160 of a preimage, OP_SIZE 32, CSV against nSequence, CLTV
/// against nLockTime). BIP68 (the spent output's age against nSequence) and
/// nLockTime finality are checked for the whole tx by Validation. Where
/// Bitcoin policy is stricter than consensus we follow policy, which only
/// ever rejects: MINIMALIF (an IF argument is empty or 0x01), NULLFAIL (a
/// signature that is checked must be valid; only the anchor's `<>` path takes
/// a false CHECKSIG, with an empty signature), NULLDUMMY, LOW_S, STRICTENC hash
/// types, and every key a CHECKSIG uses a compressed point on the curve, even
/// with an empty signature (SPEC 4.3.8; stricter than Bitcoin's STRICTENC,
/// which checks only the encoding).
library Templates {
    uint32 internal constant SEQUENCE_FINAL = 0xffffffff;
    uint32 internal constant SEQ_DISABLE = 1 << 31;
    uint32 internal constant SEQ_TYPE = 1 << 22;
    uint32 internal constant SEQ_MASK = 0xffff;
    uint32 internal constant LOCKTIME_THRESHOLD = 500_000_000;

    /// The input being spent, with its witness.
    struct Input {
        uint256 index;
        uint64 amount;
        Stack w;
    }

    // ------------------------------------------------------------ P2WPKH

    /// Witness `<sig> <33-byte compressed key>`, hash160(key) == program.
    function p2wpkh(
        bytes calldata raw_,
        TxView memory t_,
        Input memory s_,
        bytes20 program_
    ) internal view {
        Stack memory w_ = s_.w;
        if (w_.n != 2 || w_.len[1] != 33) revert BadWitness(s_.index);
        bytes memory key_ = BtcTx.item(raw_, w_, 1);
        if (ripemd160(abi.encodePacked(sha256(key_))) != program_)
            revert KeyHashMismatch(s_.index);
        // scriptCode: OP_DUP OP_HASH160 <20> OP_EQUALVERIFY OP_CHECKSIG
        _checkSig(
            raw_,
            t_,
            s_,
            BtcTx.item(raw_, w_, 0),
            key_,
            abi.encodePacked(hex"76a914", program_, hex"88ac")
        );
    }

    // ------------------------------------------------------------ P2TR key path

    /// One witness item: a 64-byte signature (DEFAULT), or 65 bytes ending in
    /// a defined hash type other than 0x00. One item means no annex and no
    /// script path.
    function p2tr(
        bytes calldata raw_,
        TxView memory t_,
        Prevout[] calldata pv_,
        uint256 index_,
        bytes32 outputKey_,
        Stack memory w_
    ) internal view {
        if (w_.n != 1) revert BadWitness(index_);
        uint256 off_ = w_.off[0];
        uint8 hashType_;
        if (w_.len[0] == 65) {
            hashType_ = uint8(raw_[off_ + 64]);
            if (hashType_ == 0 || !TaprootSighash.validHashType(hashType_))
                revert BadSignatureEncoding(index_);
        } else if (w_.len[0] != 64) {
            revert BadSignatureEncoding(index_);
        }
        // BIP341: SINGLE without an output of the same index is a failure
        // (unlike BIP143's zero hashOutputs).
        if (hashType_ & 3 == TaprootSighash.SINGLE && index_ >= BtcTx.nOut(t_))
            revert NoMatchingOutput(index_);
        uint256 rx_;
        uint256 sig_s_;
        assembly ("memory-safe") {
            rx_ := calldataload(add(raw_.offset, off_))
            sig_s_ := calldataload(add(raw_.offset, add(off_, 32)))
        }
        bytes32 digest_ = TaprootSighash.sigHash(raw_, t_, pv_, index_, hashType_);
        if (!Schnorr.verify(outputKey_, digest_, rx_, sig_s_)) revert BadSignature(index_);
    }

    // ------------------------------------------------------------ P2WSH

    function p2wsh(
        bytes calldata raw_,
        TxView memory t_,
        Input memory s_,
        bytes32 program_
    ) internal view {
        Stack memory w_ = s_.w;
        if (w_.n == 0) revert BadWitness(s_.index);
        bytes memory ws_ = BtcTx.item(raw_, w_, w_.n - 1);
        if (sha256(ws_) != program_) revert WitnessScriptMismatch(s_.index);
        uint256 len_ = ws_.length;
        bytes1 op_ = len_ == 0 ? bytes1(0xff) : ws_[0];

        if (op_ == 0x52 && len_ == 71) {
            (bool ok_, bytes memory k1_, bytes memory k2_) = matchFunding(ws_);
            if (ok_) return _spendFunding(raw_, t_, s_, ws_, k1_, k2_);
        } else if (op_ == 0x63) {
            (bool ok_, bytes memory rev_, bytes memory delayed_, uint256 delay_) = matchToLocal(
                ws_
            );
            if (ok_) return _spendToLocal(raw_, t_, s_, ws_, rev_, delayed_, delay_);
        } else if (op_ == 0x21 && len_ == 40) {
            (bool ok_, bytes memory key_) = matchAnchor(ws_);
            if (ok_) return _spendAnchor(raw_, t_, s_, ws_, key_);
        } else if (op_ == 0x21) {
            (bool ok_, bytes memory key_) = matchToRemote(ws_);
            if (ok_) return _spendToRemote(raw_, t_, s_, ws_, key_);
        } else if (op_ == 0x76) {
            (bool ok_, Htlc memory h_) = matchHtlcOffered(ws_);
            if (!ok_) (ok_, h_) = matchHtlcReceived(ws_);
            if (ok_) return _spendHtlc(raw_, t_, s_, ws_, h_);
        }
        revert UnknownWitnessScript(s_.index);
    }

    // ------------------------------------------------------------ recognisers
    // Each extracts the fields at their fixed offsets, rebuilds the script the
    // way bitcoin/script.c does, and compares all bytes.

    /// bitcoin_redeem_2of2: 2 <key1> <key2> 2 OP_CHECKMULTISIG, with
    /// key1 <= key2 (script.c sorts the keys by pubkey_cmp, a memcmp of the
    /// 33-byte encodings).
    function matchFunding(
        bytes memory ws_
    ) internal pure returns (bool, bytes memory k1_, bytes memory k2_) {
        if (ws_.length != 71) return (false, k1_, k2_);
        k1_ = _slice(ws_, 2, 33);
        k2_ = _slice(ws_, 36, 33);
        if (!_leq(k1_, k2_)) return (false, k1_, k2_);
        return (_eq(ws_, abi.encodePacked(hex"5221", k1_, hex"21", k2_, hex"52ae")), k1_, k2_);
    }

    /// bitcoin_wscript_to_local and bitcoin_wscript_htlc_tx (same script):
    /// OP_IF <revocationkey> OP_ELSE <delay> OP_CSV OP_DROP <delayedkey> OP_ENDIF OP_CHECKSIG
    function matchToLocal(
        bytes memory ws_
    ) internal pure returns (bool, bytes memory rev_, bytes memory delayed_, uint256 delay_) {
        if (ws_.length < 75 || ws_[0] != 0x63 || ws_[1] != 0x21) return (false, rev_, delayed_, 0);
        (bool ok_, uint256 d_, uint256 next_) = _readNum(ws_, 36);
        if (!ok_ || next_ + 38 != ws_.length) return (false, rev_, delayed_, 0);
        delay_ = d_;
        rev_ = _slice(ws_, 2, 33);
        delayed_ = _slice(ws_, next_ + 3, 33);
        bytes memory expect_ = abi.encodePacked(
            hex"6321",
            rev_,
            hex"67",
            _num(delay_),
            hex"b27521",
            delayed_,
            hex"68ac"
        );
        return (_eq(ws_, expect_), rev_, delayed_, delay_);
    }

    /// bitcoin_wscript_to_remote_anchored with csv_lock 1 (SPEC 4.3.7's table
    /// has only `CSV 1`; another csv_lock is a lease, SPEC 5.4):
    /// <key> OP_CHECKSIGVERIFY 1 OP_CSV
    function matchToRemote(bytes memory ws_) internal pure returns (bool, bytes memory key_) {
        if (ws_.length != 37) return (false, key_);
        key_ = _slice(ws_, 1, 33);
        return (_eq(ws_, abi.encodePacked(hex"21", key_, hex"ad51b2")), key_);
    }

    /// bitcoin_wscript_anchor: <key> OP_CHECKSIG OP_IFDUP OP_NOTIF 16 OP_CSV OP_ENDIF
    function matchAnchor(bytes memory ws_) internal pure returns (bool, bytes memory key_) {
        if (ws_.length != 40) return (false, key_);
        key_ = _slice(ws_, 1, 33);
        return (_eq(ws_, abi.encodePacked(hex"21", key_, hex"ac736460b268")), key_);
    }

    struct Htlc {
        bool offered;
        bytes20 revocationHash; // RIPEMD160(SHA256(revocationpubkey))
        bytes remoteKey;
        bytes localKey;
        bytes20 paymentHash; // RIPEMD160(payment_hash)
        uint256 cltv; // received only
    }

    /// bitcoin_wscript_htlc_offer, anchors variant:
    /// OP_DUP OP_HASH160 <revh> OP_EQUAL OP_IF OP_CHECKSIG OP_ELSE
    ///   <remotekey> OP_SWAP OP_SIZE 32 OP_EQUAL OP_NOTIF
    ///     OP_DROP 2 OP_SWAP <localkey> 2 OP_CHECKMULTISIG
    ///   OP_ELSE OP_HASH160 <ph> OP_EQUALVERIFY OP_CHECKSIG OP_ENDIF
    ///   1 OP_CSV OP_DROP OP_ENDIF
    function matchHtlcOffered(bytes memory ws_) internal pure returns (bool, Htlc memory h_) {
        if (ws_.length != 136) return (false, h_);
        h_.offered = true;
        h_.revocationHash = _bytes20(ws_, 3);
        h_.remoteKey = _slice(ws_, 28, 33);
        h_.localKey = _slice(ws_, 71, 33);
        h_.paymentHash = _bytes20(ws_, 109);
        bytes memory expect_ = abi.encodePacked(
            hex"76a914",
            h_.revocationHash,
            hex"8763ac6721",
            h_.remoteKey,
            hex"7c82012087",
            hex"6475527c21",
            h_.localKey
        );
        expect_ = abi.encodePacked(expect_, hex"52ae67a914", h_.paymentHash, hex"88ac6851b27568");
        return (_eq(ws_, expect_), h_);
    }

    /// bitcoin_wscript_htlc_receive, anchors variant:
    /// OP_DUP OP_HASH160 <revh> OP_EQUAL OP_IF OP_CHECKSIG OP_ELSE
    ///   <remotekey> OP_SWAP OP_SIZE 32 OP_EQUAL OP_IF
    ///     OP_HASH160 <ph> OP_EQUALVERIFY 2 OP_SWAP <localkey> 2 OP_CHECKMULTISIG
    ///   OP_ELSE OP_DROP <cltv> OP_CLTV OP_DROP OP_CHECKSIG OP_ENDIF
    ///   1 OP_CSV OP_DROP OP_ENDIF
    function matchHtlcReceived(bytes memory ws_) internal pure returns (bool, Htlc memory h_) {
        if (ws_.length < 139 || ws_[0] != 0x76) return (false, h_);
        (bool ok_, uint256 n_, uint256 next_) = _readNum(ws_, 130);
        if (!ok_ || next_ + 8 != ws_.length) return (false, h_);
        h_.cltv = n_;
        h_.revocationHash = _bytes20(ws_, 3);
        h_.remoteKey = _slice(ws_, 28, 33);
        h_.paymentHash = _bytes20(ws_, 69);
        h_.localKey = _slice(ws_, 93, 33);
        bytes memory expect_ = abi.encodePacked(
            hex"76a914",
            h_.revocationHash,
            hex"8763ac6721",
            h_.remoteKey,
            hex"7c82012087",
            hex"63a914",
            h_.paymentHash
        );
        expect_ = abi.encodePacked(
            expect_,
            hex"88527c21",
            h_.localKey,
            hex"52ae6775",
            _num(h_.cltv),
            hex"b175ac6851b27568"
        );
        return (_eq(ws_, expect_), h_);
    }

    // ------------------------------------------------------------ spend paths
    // s.w.n - 1 is the number of stack items before the script; item k is
    // BtcTx.item(raw, s.w, k).

    /// `<> <sig1> <sig2>`. CHECKMULTISIG pairs sig2 with key2 first, then sig1
    /// with key1; with 2 of 2 no key can be skipped, so both must be valid.
    function _spendFunding(
        bytes calldata raw_,
        TxView memory t_,
        Input memory s_,
        bytes memory ws_,
        bytes memory k1_,
        bytes memory k2_
    ) private view {
        Stack memory w_ = s_.w;
        if (w_.n != 4 || w_.len[0] != 0) revert BadWitness(s_.index); // NULLDUMMY
        _checkSig(raw_, t_, s_, BtcTx.item(raw_, w_, 1), k1_, ws_);
        _checkSig(raw_, t_, s_, BtcTx.item(raw_, w_, 2), k2_, ws_);
    }

    /// Revocation: `<revsig> <01>`. Delayed: `<delayedsig> <>` and CSV delay.
    function _spendToLocal(
        bytes calldata raw_,
        TxView memory t_,
        Input memory s_,
        bytes memory ws_,
        bytes memory rev_,
        bytes memory delayed_,
        uint256 delay_
    ) private view {
        Stack memory w_ = s_.w;
        if (w_.n != 3) revert BadWitness(s_.index);
        if (w_.len[1] == 0) {
            _csv(raw_, t_, s_.index, delay_);
            _checkSig(raw_, t_, s_, BtcTx.item(raw_, w_, 0), delayed_, ws_);
        } else if (w_.len[1] == 1 && raw_[w_.off[1]] == 0x01) {
            _checkSig(raw_, t_, s_, BtcTx.item(raw_, w_, 0), rev_, ws_);
        } else {
            revert BadWitness(s_.index); // MINIMALIF
        }
    }

    /// `<sig>` and CSV 1: CHECKSIGVERIFY, then 1 CSV leaves 1 as the result.
    function _spendToRemote(
        bytes calldata raw_,
        TxView memory t_,
        Input memory s_,
        bytes memory ws_,
        bytes memory key_
    ) private view {
        if (s_.w.n != 2) revert BadWitness(s_.index);
        _checkSig(raw_, t_, s_, BtcTx.item(raw_, s_.w, 0), key_, ws_);
        _csv(raw_, t_, s_.index, 1);
    }

    /// `<sig>` at any time, or `<>` and CSV 16 (CHECKSIG is false, IFDUP
    /// leaves nothing, NOTIF runs 16 CSV, which leaves 16 as the true result).
    function _spendAnchor(
        bytes calldata raw_,
        TxView memory t_,
        Input memory s_,
        bytes memory ws_,
        bytes memory key_
    ) private view {
        if (s_.w.n != 2) revert BadWitness(s_.index);
        if (s_.w.len[0] == 0) {
            _key(s_.index, key_); // CHECKSIG still checks the key
            _csv(raw_, t_, s_.index, 16);
        } else {
            _checkSig(raw_, t_, s_, BtcTx.item(raw_, s_.w, 0), key_, ws_);
        }
    }

    /// The path is chosen by the top stack item x, as in Script, and each
    /// path's stack is exactly the one in SPEC 4.3.7's table:
    /// - HASH160(x) == revocation hash: `<revsig> <revocationpubkey>`.
    /// - offered, x a 32-byte preimage: remote success, `<remotesig> <x>`, CSV 1.
    /// - offered, x empty: HTLC-timeout tx, `<> <remotesig> <localsig> <>`, CSV 1.
    /// - received, x a 32-byte preimage: HTLC-success tx,
    ///   `<> <remotesig> <localsig> <x>`, CSV 1.
    /// - received, x empty: remote timeout, `<sig> <>`, CLTV cltv_expiry, CSV 1.
    /// A 32-byte x must hash to the payment hash. CHECKMULTISIG's key order is
    /// (remotekey, localkey), so the remote signature comes first.
    function _spendHtlc(
        bytes calldata raw_,
        TxView memory t_,
        Input memory s_,
        bytes memory ws_,
        Htlc memory h_
    ) private view {
        uint256 n_ = s_.w.n - 1; // stack items before the script
        if (n_ == 0) revert BadWitness(s_.index);
        bytes memory x_ = BtcTx.item(raw_, s_.w, n_ - 1);
        bytes20 xh_ = ripemd160(abi.encodePacked(sha256(x_)));
        if (xh_ == h_.revocationHash) {
            if (n_ != 2) revert BadWitness(s_.index);
            _checkSig(raw_, t_, s_, BtcTx.item(raw_, s_.w, 0), x_, ws_);
            return;
        }
        bool preimage_ = x_.length == 32;
        if (!preimage_ && x_.length != 0) revert BadWitness(s_.index);
        if (preimage_ && xh_ != h_.paymentHash) revert BadPreimage(s_.index);
        if (preimage_ != h_.offered) {
            // the 2-of-2 to the HTLC-success (received) or HTLC-timeout (offered) tx
            if (n_ != 4 || s_.w.len[0] != 0) revert BadWitness(s_.index); // NULLDUMMY
            _checkSig(raw_, t_, s_, BtcTx.item(raw_, s_.w, 1), h_.remoteKey, ws_);
            _checkSig(raw_, t_, s_, BtcTx.item(raw_, s_.w, 2), h_.localKey, ws_);
        } else {
            // remote success (offered) or remote timeout (received)
            if (n_ != 2) revert BadWitness(s_.index);
            if (!h_.offered) _cltv(raw_, t_, s_.index, h_.cltv);
            _checkSig(raw_, t_, s_, BtcTx.item(raw_, s_.w, 0), h_.remoteKey, ws_);
        }
        _csv(raw_, t_, s_.index, 1);
    }

    // ------------------------------------------------------------ opcodes

    /// OP_CHECKSIG under NULLFAIL: the signature must be valid.
    function _checkSig(
        bytes calldata raw_,
        TxView memory t_,
        Input memory s_,
        bytes memory sig_,
        bytes memory pubkey_,
        bytes memory scriptCode_
    ) private view {
        (bool ok_, uint256 r_, uint256 sigS_, uint8 hashType_) = Ecdsa.parse(sig_);
        if (!ok_ || !Bip143.validHashType(hashType_)) revert BadSignatureEncoding(s_.index);
        bytes32 digest_ = Bip143.sigHash(raw_, t_, s_.index, scriptCode_, s_.amount, hashType_);
        _verify(s_.index, pubkey_, digest_, r_, sigS_);
    }

    function _verify(
        uint256 index_,
        bytes memory pubkey_,
        bytes32 digest_,
        uint256 r_,
        uint256 sigS_
    ) private view {
        (uint256 x_, uint256 y_) = _key(index_, pubkey_);
        if (!Ecdsa.verify(x_, y_, digest_, r_, sigS_)) revert BadSignature(index_);
    }

    /// A key a CHECKSIG uses: a 33-byte compressed point on the curve.
    function _key(
        uint256 index_,
        bytes memory pubkey_
    ) private view returns (uint256 x_, uint256 y_) {
        bool ok_;
        (ok_, x_, y_) = Ecdsa.liftKey(pubkey_);
        if (!ok_) revert BadPublicKey(index_);
    }

    /// `CSV n`, Bitcoin's CheckSequence as SPEC 4.3.7 defines it: the tx
    /// version (a uint32) is at least 2, the input's sequence has the disable
    /// bit (31) clear and the type bit (22) clear (n is always a number of
    /// blocks here), and sequence & 0xffff >= n. BIP68 (SPEC 4.3.6) applies
    /// on top, in Validation.
    /// @dev n is compared whole, so an n of 2^16 or more (which no CLN script
    /// has: to_self_delay is a u16, and leases are refused by the plugin) is
    /// never met, and a to_local script with such a delay is unspendable. Bitcoin would treat an n with bit 31 set as a NOP and
    /// compare only n's low 16 bits and type bit otherwise; this only rejects more.
    function _csv(bytes calldata raw_, TxView memory t_, uint256 index_, uint256 n_) private pure {
        uint32 seq_ = BtcTx.sequence(raw_, t_, index_);
        if (
            t_.version < 2 ||
            seq_ & SEQ_DISABLE != 0 ||
            seq_ & SEQ_TYPE != 0 ||
            (seq_ & SEQ_MASK) < n_
        ) {
            revert CsvNotMet(index_);
        }
    }

    /// `CLTV x`, Bitcoin's CheckLockTime: nLockTime and x are both heights
    /// (< 500,000,000) or both times, nLockTime >= x, and the input's sequence
    /// is not final. nLockTime finality itself (SPEC 4.3.5) is in Validation.
    function _cltv(
        bytes calldata raw_,
        TxView memory t_,
        uint256 index_,
        uint256 x_
    ) private pure {
        uint32 lt_ = t_.locktime;
        if ((x_ < LOCKTIME_THRESHOLD) != (lt_ < LOCKTIME_THRESHOLD) || lt_ < x_)
            revert CltvNotMet(index_);
        if (BtcTx.sequence(raw_, t_, index_) == SEQUENCE_FINAL) revert CltvNotMet(index_);
    }

    // ------------------------------------------------------------ script numbers and bytes

    /// A script number pushed by bitcoin/script.c add_number() at ws[off]:
    /// OP_0, OP_1..OP_16, or a 1-5 byte push of a non-negative little-endian
    /// number (a CScriptNum of up to 5 bytes). Minimality is not checked here;
    /// callers rebuild the script with _num() and compare, which rejects every
    /// other encoding.
    function _readNum(
        bytes memory ws_,
        uint256 off_
    ) private pure returns (bool ok_, uint256 v_, uint256 next_) {
        if (off_ >= ws_.length) return (false, 0, 0);
        uint8 op_ = uint8(ws_[off_]);
        if (op_ == 0) return (true, 0, off_ + 1);
        if (op_ >= 0x51 && op_ <= 0x60) return (true, op_ - 0x50, off_ + 1);
        if (op_ < 1 || op_ > 5 || off_ + 1 + op_ > ws_.length) return (false, 0, 0);
        for (uint256 i; i < op_; ++i) {
            v_ |= uint256(uint8(ws_[off_ + 1 + i])) << (8 * i);
        }
        if (uint8(ws_[off_ + op_]) & 0x80 != 0) return (false, 0, 0); // negative
        // add_number() takes a u32: a bigger number is not a CLN script
        if (v_ > type(uint32).max) return (false, 0, 0);
        return (true, v_, off_ + 1 + op_);
    }

    /// bitcoin/script.c add_number() (minimal, non-negative CScriptNum).
    function _num(uint256 v_) private pure returns (bytes memory) {
        if (v_ == 0) return hex"00";
        if (v_ <= 16) return abi.encodePacked(uint8(0x50 + v_));
        uint256 len_ =
            v_ <= 0x7f
                ? 1
                : v_ <= 0x7fff
                    ? 2
                    : v_ <= 0x7fffff
                        ? 3
                        : v_ <= 0x7fffffff
                            ? 4
                            : 5;
        bytes memory b_ = new bytes(len_ + 1);
        b_[0] = bytes1(uint8(len_));
        for (uint256 i; i < len_; ++i) {
            b_[1 + i] = bytes1(uint8(v_ >> (8 * i)));
        }
        return b_;
    }

    function _eq(bytes memory a_, bytes memory b_) private pure returns (bool) {
        return a_.length == b_.length && keccak256(a_) == keccak256(b_);
    }

    /// a <= b for two 33-byte strings, as memcmp orders them.
    function _leq(bytes memory a_, bytes memory b_) private pure returns (bool) {
        uint256 a0_;
        uint256 b0_;
        uint256 a1_;
        uint256 b1_;
        assembly ("memory-safe") {
            a0_ := mload(add(a_, 32))
            b0_ := mload(add(b_, 32))
            a1_ := byte(0, mload(add(a_, 64)))
            b1_ := byte(0, mload(add(b_, 64)))
        }
        return a0_ < b0_ || (a0_ == b0_ && a1_ <= b1_);
    }

    function _bytes20(bytes memory b_, uint256 off_) private pure returns (bytes20) {
        // An internal bound that no caller can miss: kept without a reason so the
        // bytecode stays that of the reviewed build.
        // slippy-disable-next-line require-revert-reason
        require(off_ + 20 <= b_.length);
        bytes32 w_;
        assembly ("memory-safe") {
            w_ := mload(add(add(b_, 32), off_))
        }
        return bytes20(w_);
    }

    function _slice(
        bytes memory b_,
        uint256 off_,
        uint256 len_
    ) private pure returns (bytes memory out_) {
        // slippy-disable-next-line require-revert-reason
        require(off_ + len_ <= b_.length);
        out_ = new bytes(len_);
        assembly ("memory-safe") {
            mcopy(add(out_, 32), add(add(b_, 32), off_), len_)
        }
    }
}
