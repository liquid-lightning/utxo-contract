// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    TxTooLarge,
    Truncated,
    NonCanonicalCompactSize,
    BadSegwitFlag,
    EmptyWitnesses,
    NoInputs,
    NoOutputs,
    TrailingBytes,
    ScriptSigNotEmpty,
    BadWitness
} from "../utils/Errors.sol";

/// An output being spent, as `submit` takes it (SPEC 4.2). `height` is the
/// height it was created at. All three are bound to the UTXO set by
/// utxo[key] == keccak256(amount, scriptPubKey, height).
struct Prevout {
    uint64 amount;
    bytes scriptPubKey;
    uint32 height;
}

/// A parsed transaction: offsets into the raw bytes (calldata) rather than
/// copies, plus the hashes of its parts, computed on first use.
///
/// Every scriptSig is empty (the parser rejects any other, SPEC 4.3.2), so
/// every input is 41 bytes and input i starts at inStart + 41 * i:
/// prevout txid (32), prevout index (4, LE), scriptSig length 0x00 (1),
/// sequence (4, LE).
struct TxView {
    uint32 version;
    uint32 locktime;
    uint256 nIn;
    uint256 inStart; // offset of input 0
    uint256 bodyStart; // offset of the input count (after the segwit marker and flag)
    /// outOff[j] is the offset of output j, outOff[nOut] the end of the last
    /// output, so output j is raw[outOff[j]:outOff[j + 1]].
    uint256[] outOff;
    /// Offset of input i's witness (its item count), or NO_WITNESS.
    uint256[] witOff;
    bytes32 txid; // double SHA256 of the serialization without witness, internal byte order
    // Single SHA256 of the concatenations BIP341 defines (BIP143 hashes each
    // once more). Bit k of `have` is set once the k-th of them is computed.
    uint256 have;
    bytes32 shaPrevouts;
    bytes32 shaSequences;
    bytes32 shaOutputs;
    bytes32 shaAmounts;
    bytes32 shaScripts;
}

/// The witness items of one input, as offsets and lengths in the raw tx.
/// No template has more than 5 items (HTLC-success: 4 and the script), so a
/// longer witness is rejected when it is read.
struct Stack {
    uint256 n;
    uint256[5] off;
    uint256[5] len;
}

/// @title Strict parser for segwit transactions, reading calldata in place.
/// @notice SPEC 4.3.1: at most 100,000 bytes; canonical compact sizes; no
/// trailing bytes; marker and flag 00 01, and only if some witness is
/// non-empty; at least one input and one output; the version as a uint32.
/// SPEC 4.3.2's empty scriptSig is enforced here too.
library BtcTx {
    uint256 internal constant MAX_TX_SIZE = 100_000;
    uint256 internal constant INPUT_SIZE = 41;
    uint256 internal constant MAX_STACK = 5;
    uint256 internal constant NO_WITNESS = type(uint256).max;

    uint256 private constant HAVE_PREVOUTS = 1;
    uint256 private constant HAVE_SEQUENCES = 2;
    uint256 private constant HAVE_OUTPUTS = 4;
    uint256 private constant HAVE_AMOUNTS = 8;
    uint256 private constant HAVE_SCRIPTS = 16;

    function parse(bytes calldata raw_) internal pure returns (TxView memory t_) {
        uint256 len_ = raw_.length;
        if (len_ > MAX_TX_SIZE) revert TxTooLarge();
        t_.version = uint32(le(raw_, 0, 4));
        uint256 off_ = 4;
        bool segwit_;
        if (u8(raw_, 4) == 0) {
            if (u8(raw_, 5) != 1) revert BadSegwitFlag();
            segwit_ = true;
            off_ = 6;
        }
        t_.bodyStart = off_;

        uint256 n_;
        (n_, off_) = compactSize(raw_, off_);
        if (n_ == 0) revert NoInputs();
        if (n_ > (len_ - off_) / INPUT_SIZE) revert Truncated();
        t_.nIn = n_;
        t_.inStart = off_;
        for (uint256 i; i < n_; ++i) {
            if (u8(raw_, off_ + 36) != 0) revert ScriptSigNotEmpty(i);
            off_ += INPUT_SIZE;
        }

        (n_, off_) = compactSize(raw_, off_);
        if (n_ == 0) revert NoOutputs();
        if (n_ > (len_ - off_) / 9) revert Truncated();
        uint256[] memory outOff_ = new uint256[](n_ + 1);
        for (uint256 j; j < n_; ++j) {
            outOff_[j] = off_;
            uint256 sl_;
            (sl_, off_) = compactSize(raw_, off_ + 8);
            if (sl_ > len_ - off_) revert Truncated();
            off_ += sl_;
        }
        outOff_[n_] = off_;
        t_.outOff = outOff_;

        uint256 nIn_ = t_.nIn;
        uint256[] memory witOff_ = new uint256[](nIn_);
        if (segwit_) {
            bool any_;
            for (uint256 i; i < nIn_; ++i) {
                witOff_[i] = off_;
                uint256 items_;
                (items_, off_) = compactSize(raw_, off_);
                if (items_ > len_ - off_) revert Truncated();
                if (items_ != 0) any_ = true;
                for (uint256 k; k < items_; ++k) {
                    uint256 il_;
                    (il_, off_) = compactSize(raw_, off_);
                    if (il_ > len_ - off_) revert Truncated();
                    off_ += il_;
                }
            }
            if (!any_) revert EmptyWitnesses();
        } else {
            for (uint256 i; i < nIn_; ++i) {
                witOff_[i] = NO_WITNESS;
            }
        }
        t_.witOff = witOff_;

        if (off_ + 4 > len_) revert Truncated();
        if (off_ + 4 != len_) revert TrailingBytes();
        t_.locktime = uint32(le(raw_, off_, 4));

        // txid: the serialization without marker, flag and witnesses, which
        // is the raw tx with those three parts left out.
        bytes32 h_ =
            segwit_
                ? sha256(
                    abi.encodePacked(raw_[0:4], raw_[t_.bodyStart:outOff_[n_]], raw_[off_:len_])
                )
                : sha256(raw_);
        t_.txid = sha256(abi.encodePacked(h_));
    }

    // ------------------------------------------------------------ fields

    function inputOffset(TxView memory t_, uint256 i_) internal pure returns (uint256) {
        return t_.inStart + INPUT_SIZE * i_;
    }

    function prevTxid(
        bytes calldata raw_,
        TxView memory t_,
        uint256 i_
    ) internal pure returns (bytes32 w_) {
        uint256 off_ = inputOffset(t_, i_);
        assembly ("memory-safe") {
            w_ := calldataload(add(raw_.offset, off_))
        }
    }

    function prevVout(
        bytes calldata raw_,
        TxView memory t_,
        uint256 i_
    ) internal pure returns (uint32) {
        return uint32(le(raw_, inputOffset(t_, i_) + 32, 4));
    }

    function sequence(
        bytes calldata raw_,
        TxView memory t_,
        uint256 i_
    ) internal pure returns (uint32) {
        return uint32(le(raw_, inputOffset(t_, i_) + 37, 4));
    }

    function nOut(TxView memory t_) internal pure returns (uint256) {
        return t_.outOff.length - 1;
    }

    function outAmount(
        bytes calldata raw_,
        TxView memory t_,
        uint256 j_
    ) internal pure returns (uint64) {
        return uint64(le(raw_, t_.outOff[j_], 8));
    }

    function outScript(
        bytes calldata raw_,
        TxView memory t_,
        uint256 j_
    ) internal pure returns (bytes calldata) {
        (uint256 sl_, uint256 off_) = compactSize(raw_, t_.outOff[j_] + 8);
        return raw_[off_:off_ + sl_];
    }

    /// Output j as it is serialized (amount, compact size, script).
    function outBytes(
        bytes calldata raw_,
        TxView memory t_,
        uint256 j_
    ) internal pure returns (bytes calldata) {
        return raw_[t_.outOff[j_]:t_.outOff[j_ + 1]];
    }

    /// The witness of input i. Reverts with BadWitness(i) above 5 items.
    function stack(
        bytes calldata raw_,
        TxView memory t_,
        uint256 i_
    ) internal pure returns (Stack memory s_) {
        uint256 off_ = t_.witOff[i_];
        if (off_ == NO_WITNESS) return s_;
        (s_.n, off_) = compactSize(raw_, off_);
        if (s_.n > MAX_STACK) revert BadWitness(i_);
        for (uint256 k; k < s_.n; ++k) {
            (s_.len[k], off_) = compactSize(raw_, off_);
            s_.off[k] = off_;
            off_ += s_.len[k];
        }
    }

    function item(
        bytes calldata raw_,
        Stack memory s_,
        uint256 k_
    ) internal pure returns (bytes calldata) {
        return raw_[s_.off[k_]:s_.off[k_] + s_.len[k_]];
    }

    // ------------------------------------------------------------ hashes of the parts (BIP341 names)

    /// sha_prevouts: SHA256 of every input's outpoint.
    function shaPrevouts(bytes calldata raw_, TxView memory t_) internal pure returns (bytes32) {
        if (t_.have & HAVE_PREVOUTS == 0) {
            t_.shaPrevouts = sha256(_gather(raw_, t_.inStart, t_.nIn, 36, 0));
            t_.have |= HAVE_PREVOUTS;
        }
        return t_.shaPrevouts;
    }

    /// sha_sequences: SHA256 of every input's sequence.
    function shaSequences(bytes calldata raw_, TxView memory t_) internal pure returns (bytes32) {
        if (t_.have & HAVE_SEQUENCES == 0) {
            t_.shaSequences = sha256(_gather(raw_, t_.inStart, t_.nIn, 4, 37));
            t_.have |= HAVE_SEQUENCES;
        }
        return t_.shaSequences;
    }

    /// sha_outputs: SHA256 of the serialized outputs, which lie contiguous in the raw tx.
    function shaOutputs(bytes calldata raw_, TxView memory t_) internal pure returns (bytes32) {
        if (t_.have & HAVE_OUTPUTS == 0) {
            t_.shaOutputs = sha256(raw_[t_.outOff[0]:t_.outOff[t_.outOff.length - 1]]);
            t_.have |= HAVE_OUTPUTS;
        }
        return t_.shaOutputs;
    }

    /// sha_amounts: SHA256 of every spent amount (8 bytes LE each).
    function shaAmounts(TxView memory t_, Prevout[] calldata pv_) internal pure returns (bytes32) {
        if (t_.have & HAVE_AMOUNTS == 0) {
            uint256 n_ = pv_.length;
            bytes memory b_ = new bytes(8 * n_ + 32); // room for the last 32-byte store
            for (uint256 i; i < n_; ++i) {
                bytes8 a_ = le64(pv_[i].amount);
                assembly ("memory-safe") {
                    mstore(add(add(b_, 32), mul(8, i)), a_)
                }
            }
            assembly ("memory-safe") {
                mstore(b_, mul(8, n_))
            }
            t_.shaAmounts = sha256(b_);
            t_.have |= HAVE_AMOUNTS;
        }
        return t_.shaAmounts;
    }

    /// sha_scriptpubkeys: SHA256 of every spent scriptPubKey with its compact size.
    function shaScripts(TxView memory t_, Prevout[] calldata pv_) internal pure returns (bytes32) {
        if (t_.have & HAVE_SCRIPTS == 0) {
            // one allocation (a loop of abi.encodePacked would copy the
            // buffer for every input: quadratic memory)
            uint256 total_;
            for (uint256 i; i < pv_.length; ++i) {
                total_ +=
                    compactSizeBytes(pv_[i].scriptPubKey.length).length +
                    pv_[i].scriptPubKey.length;
            }
            bytes memory b_ = new bytes(total_);
            uint256 at_;
            for (uint256 i; i < pv_.length; ++i) {
                bytes memory size_ = compactSizeBytes(pv_[i].scriptPubKey.length);
                bytes calldata spk_ = pv_[i].scriptPubKey;
                assembly ("memory-safe") {
                    let dst := add(add(b_, 32), at_)
                    mcopy(dst, add(size_, 32), mload(size_))
                    calldatacopy(add(dst, mload(size_)), spk_.offset, spk_.length)
                }
                at_ += size_.length + spk_.length;
            }
            t_.shaScripts = sha256(b_);
            t_.have |= HAVE_SCRIPTS;
        }
        return t_.shaScripts;
    }

    /// n fields of `width` bytes, the first at raw[start + skip], one per 41-byte input.
    function _gather(
        bytes calldata raw_,
        uint256 start_,
        uint256 n_,
        uint256 width_,
        uint256 skip_
    ) private pure returns (bytes memory b_) {
        b_ = new bytes(n_ * width_);
        assembly ("memory-safe") {
            let dst := add(b_, 32)
            let src := add(add(raw_.offset, start_), skip_)
            for {
                let i := 0
            } lt(i, n_) {
                i := add(i, 1)
            } {
                calldatacopy(add(dst, mul(i, width_)), add(src, mul(i, 41)), width_)
            }
        }
    }

    // ------------------------------------------------------------ primitives

    function u8(bytes calldata raw_, uint256 off_) internal pure returns (uint256 v_) {
        if (off_ >= raw_.length) revert Truncated();
        assembly ("memory-safe") {
            v_ := byte(0, calldataload(add(raw_.offset, off_)))
        }
    }

    /// Little-endian unsigned integer of `len` (1 to 8) bytes at raw[off].
    function le(
        bytes calldata raw_,
        uint256 off_,
        uint256 len_
    ) internal pure returns (uint256 v_) {
        if (off_ + len_ > raw_.length) revert Truncated();
        uint64 w_;
        assembly ("memory-safe") {
            // the 8 bytes at raw[off] as a big-endian uint64 (past the end of
            // calldata, calldataload reads zeros)
            w_ := shr(192, calldataload(add(raw_.offset, off_)))
        }
        // byte-reversed, the first byte is the lowest; keep the first `len`
        v_ = uint64(le64(w_)) & ((1 << (8 * len_)) - 1);
    }

    /// A canonical compact size at raw[off], and the offset after it.
    function compactSize(
        bytes calldata raw_,
        uint256 off_
    ) internal pure returns (uint256 v_, uint256 next_) {
        uint256 first_ = u8(raw_, off_);
        if (first_ < 0xfd) return (first_, off_ + 1);
        if (first_ == 0xfd) {
            v_ = le(raw_, off_ + 1, 2);
            if (v_ < 0xfd) revert NonCanonicalCompactSize();
            return (v_, off_ + 3);
        }
        if (first_ == 0xfe) {
            v_ = le(raw_, off_ + 1, 4);
            if (v_ <= 0xffff) revert NonCanonicalCompactSize();
            return (v_, off_ + 5);
        }
        v_ = le(raw_, off_ + 1, 8);
        if (v_ <= 0xffffffff) revert NonCanonicalCompactSize();
        return (v_, off_ + 9);
    }

    function compactSizeBytes(uint256 n_) internal pure returns (bytes memory) {
        if (n_ < 0xfd) return abi.encodePacked(uint8(n_));
        if (n_ <= 0xffff) return abi.encodePacked(uint8(0xfd), bytes2(le16(uint16(n_))));
        if (n_ <= 0xffffffff) return abi.encodePacked(uint8(0xfe), le32(uint32(n_)));
        return abi.encodePacked(uint8(0xff), le64(uint64(n_)));
    }

    function le16(uint16 x_) internal pure returns (bytes2) {
        return bytes2((x_ >> 8) | (x_ << 8));
    }

    function le32(uint32 x_) internal pure returns (bytes4) {
        x_ = ((x_ & 0xff00ff00) >> 8) | ((x_ & 0x00ff00ff) << 8);
        x_ = (x_ >> 16) | (x_ << 16);
        return bytes4(x_);
    }

    function le64(uint64 x_) internal pure returns (bytes8) {
        x_ = ((x_ & 0xff00ff00ff00ff00) >> 8) | ((x_ & 0x00ff00ff00ff00ff) << 8);
        x_ = ((x_ & 0xffff0000ffff0000) >> 16) | ((x_ & 0x0000ffff0000ffff) << 16);
        x_ = (x_ >> 32) | (x_ << 32);
        return bytes8(x_);
    }
}
