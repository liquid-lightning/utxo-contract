// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BtcTx, TxView} from "../bitcoin/BtcTx.sol";
import {
    TxTooLarge,
    Truncated,
    BadSegwitFlag,
    EmptyWitnesses,
    NoInputs,
    NoOutputs,
    TrailingBytes,
    ScriptSigNotEmpty,
    IssuanceOrPegin,
    NotExplicit,
    NonEmptyProof
} from "../utils/Errors.sol";

/// An output being spent, as the multi-asset chain's `submit` takes it.
/// `asset` is the 32 bytes of the output's explicit asset tag, as they are
/// serialized in the transaction; `height` is the height it was created at.
/// All four are bound to the UTXO set by
/// utxo[key] == keccak256(asset, amount, scriptPubKey, height).
struct AssetPrevout {
    bytes32 asset;
    uint64 amount;
    bytes scriptPubKey;
    uint32 height;
}

/// @title Strict parser for the explicit subset of Elements transactions,
/// reading calldata in place.
/// @notice The serialization is Elements' (as libwally writes it):
///
///   version (4, LE) | flag (1) | inputs | outputs | locktime (4, LE) | witnesses
///
/// - flag is 0x01 when a witness section follows and 0x00 otherwise; unlike
///   Bitcoin's marker and flag it is always there. It is 0x01 only if some
///   script witness is non-empty.
/// - an input is its outpoint (txid 32, index 4 LE), an empty scriptSig and
///   its sequence (4 LE): 41 bytes, as in Bitcoin. The index must have the
///   issuance (bit 31) and peg-in (bit 30) bits clear, so no input carries an
///   asset issuance.
/// - an output is its asset (0x01 and 32 bytes), its value (0x01 and 8 bytes,
///   big-endian), an empty nonce (0x00) and its scriptPubKey. Anything else
///   there is a confidential output, which is rejected.
/// - the witness section has, per input, two empty range proofs (0x00 0x00),
///   the script witness stack and an empty peg-in witness (0x00); then, per
///   output, an empty surjection proof and an empty range proof (0x00 0x00).
/// - txid is the double SHA256 of the serialization with flag 0x00 and no
///   witness section.
///
/// The result is a `TxView`, the same as BtcTx's, so the accessors of BtcTx
/// that only look at inputs and witnesses (and the contiguous outputs) work
/// on it; the ones that read an output's fields are here.
library ElementsTx {
    uint256 internal constant MAX_TX_SIZE = 100_000;
    uint256 internal constant INPUT_SIZE = 41;
    /// asset (33), value (9), nonce (1) and an empty script (1)
    uint256 internal constant MIN_OUTPUT_SIZE = 44;
    uint256 internal constant EXPLICIT = 0x01;

    function parse(bytes calldata raw_) internal pure returns (TxView memory t_) {
        uint256 len_ = raw_.length;
        if (len_ > MAX_TX_SIZE) revert TxTooLarge();
        t_.version = uint32(BtcTx.le(raw_, 0, 4));
        uint256 flag_ = BtcTx.u8(raw_, 4);
        if (flag_ > 1) revert BadSegwitFlag();
        t_.bodyStart = 5;

        uint256 off_ = _parseInputs(raw_, t_, 5);
        off_ = _parseOutputs(raw_, t_, off_);

        if (off_ + 4 > len_) revert Truncated();
        t_.locktime = uint32(BtcTx.le(raw_, off_, 4));
        uint256 bodyEnd_ = off_ + 4;

        off_ = _parseWitnesses(raw_, t_, bodyEnd_, flag_ == 1);
        if (off_ != len_) revert TrailingBytes();

        // txid: the serialization with flag 0x00 and without the witnesses
        t_.txid = sha256(
            abi.encodePacked(sha256(abi.encodePacked(raw_[0:4], bytes1(0), raw_[5:bodyEnd_])))
        );
    }

    // ------------------------------------------------------------ fields

    /// The 32 bytes of output j's explicit asset tag.
    function outAsset(
        bytes calldata raw_,
        TxView memory t_,
        uint256 j_
    ) internal pure returns (bytes32 asset_) {
        uint256 off_ = t_.outOff[j_] + 1;
        assembly ("memory-safe") {
            asset_ := calldataload(add(raw_.offset, off_))
        }
    }

    /// Output j's explicit value (8 bytes, big-endian).
    function outAmount(
        bytes calldata raw_,
        TxView memory t_,
        uint256 j_
    ) internal pure returns (uint64 amount_) {
        uint256 off_ = t_.outOff[j_] + 34;
        assembly ("memory-safe") {
            amount_ := shr(192, calldataload(add(raw_.offset, off_)))
        }
    }

    function outScript(
        bytes calldata raw_,
        TxView memory t_,
        uint256 j_
    ) internal pure returns (bytes calldata) {
        (uint256 sl_, uint256 off_) = BtcTx.compactSize(raw_, t_.outOff[j_] + 43);
        return raw_[off_:off_ + sl_];
    }

    /// The offset of nLockTime: it follows the outputs.
    function locktimeOffset(TxView memory t_) internal pure returns (uint256) {
        return t_.outOff[t_.outOff.length - 1];
    }

    // ------------------------------------------------------------ parts

    function _parseInputs(
        bytes calldata raw_,
        TxView memory t_,
        uint256 off_
    ) private pure returns (uint256) {
        uint256 n_;
        (n_, off_) = BtcTx.compactSize(raw_, off_);
        if (n_ == 0) revert NoInputs();
        if (n_ > (raw_.length - off_) / INPUT_SIZE) revert Truncated();
        t_.nIn = n_;
        t_.inStart = off_;
        for (uint256 i; i < n_; ++i) {
            // the index's top byte (it is little-endian) holds bits 31 and 30
            if (BtcTx.u8(raw_, off_ + 35) & 0xc0 != 0) revert IssuanceOrPegin(i);
            if (BtcTx.u8(raw_, off_ + 36) != 0) revert ScriptSigNotEmpty(i);
            off_ += INPUT_SIZE;
        }
        return off_;
    }

    function _parseOutputs(
        bytes calldata raw_,
        TxView memory t_,
        uint256 off_
    ) private pure returns (uint256) {
        uint256 len_ = raw_.length;
        uint256 n_;
        (n_, off_) = BtcTx.compactSize(raw_, off_);
        if (n_ == 0) revert NoOutputs();
        if (n_ > (len_ - off_) / MIN_OUTPUT_SIZE) revert Truncated();
        uint256[] memory outOff_ = new uint256[](n_ + 1);
        for (uint256 j; j < n_; ++j) {
            outOff_[j] = off_;
            if (
                BtcTx.u8(raw_, off_) != EXPLICIT ||
                BtcTx.u8(raw_, off_ + 33) != EXPLICIT ||
                BtcTx.u8(raw_, off_ + 42) != 0
            ) revert NotExplicit(j);
            uint256 sl_;
            (sl_, off_) = BtcTx.compactSize(raw_, off_ + 43);
            if (sl_ > len_ - off_) revert Truncated();
            off_ += sl_;
        }
        outOff_[n_] = off_;
        t_.outOff = outOff_;
        return off_;
    }

    function _parseWitnesses(
        bytes calldata raw_,
        TxView memory t_,
        uint256 off_,
        bool present_
    ) private pure returns (uint256) {
        uint256 nIn_ = t_.nIn;
        uint256[] memory witOff_ = new uint256[](nIn_);
        t_.witOff = witOff_;
        if (!present_) {
            for (uint256 i; i < nIn_; ++i) {
                witOff_[i] = BtcTx.NO_WITNESS;
            }
            return off_;
        }
        uint256 len_ = raw_.length;
        bool any_;
        for (uint256 i; i < nIn_; ++i) {
            // the issuance amount and inflation keys range proofs
            if (BtcTx.le(raw_, off_, 2) != 0) revert NonEmptyProof();
            off_ += 2;
            witOff_[i] = off_;
            uint256 items_;
            (items_, off_) = BtcTx.compactSize(raw_, off_);
            if (items_ > len_ - off_) revert Truncated();
            if (items_ != 0) any_ = true;
            for (uint256 k; k < items_; ++k) {
                uint256 il_;
                (il_, off_) = BtcTx.compactSize(raw_, off_);
                if (il_ > len_ - off_) revert Truncated();
                off_ += il_;
            }
            // the peg-in witness
            if (BtcTx.u8(raw_, off_) != 0) revert NonEmptyProof();
            off_ += 1;
        }
        if (!any_) revert EmptyWitnesses();
        // per output: the surjection proof and the range proof
        uint256 nOut_ = t_.outOff.length - 1;
        for (uint256 j; j < nOut_; ++j) {
            if (BtcTx.le(raw_, off_, 2) != 0) revert NonEmptyProof();
            off_ += 2;
        }
        return off_;
    }
}
