// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BtcTx, TxView, Prevout} from "./BtcTx.sol";

/// @title BIP341 signature hash for key-path spends (ext_flag 0, no annex),
/// hash types DEFAULT, ALL, NONE, SINGLE, each optionally with ANYONECANPAY
/// (SPEC 4.3.9).
library TaprootSighash {
    /// sha256("TapSighash")
    bytes32 internal constant TAG =
        0xf40a48df4b2a70c8b4924bf2654661ed3d95fd66a313eb87237597c628e4a031;

    uint8 internal constant DEFAULT = 0x00;
    uint8 internal constant NONE = 0x02;
    uint8 internal constant SINGLE = 0x03;
    uint8 internal constant ANYONECANPAY = 0x80;

    function validHashType(uint8 hashType_) internal pure returns (bool) {
        return hashType_ <= 0x03 || (hashType_ >= 0x81 && hashType_ <= 0x83);
    }

    /// @notice The BIP341 signature message, prefixed with the epoch byte 0x00
    /// (what the BIP341 vectors call sigMsg).
    /// @dev hashType must satisfy validHashType, and for SINGLE `index` must
    /// have an output of the same index (BIP341 makes it a failure; the caller
    /// checks it).
    function sigMsg(
        bytes calldata raw_,
        TxView memory t_,
        Prevout[] calldata pv_,
        uint256 index_,
        uint8 hashType_
    ) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                _txPart(raw_, t_, pv_, hashType_),
                _inputPart(raw_, t_, pv_, index_, hashType_)
            );
    }

    /// epoch, hash_type, nVersion, nLockTime, the hashes the type commits to,
    /// spend_type
    function _txPart(
        bytes calldata raw_,
        TxView memory t_,
        Prevout[] calldata pv_,
        uint8 hashType_
    ) private pure returns (bytes memory m_) {
        uint8 base_ = hashType_ & 3;
        m_ = abi.encodePacked(uint8(0), hashType_, raw_[0:4], raw_[raw_.length - 4:raw_.length]);
        if (hashType_ & ANYONECANPAY == 0) {
            bytes32 prevouts_ = BtcTx.shaPrevouts(raw_, t_);
            bytes32 amounts_ = BtcTx.shaAmounts(t_, pv_);
            bytes32 scripts_ = BtcTx.shaScripts(t_, pv_);
            m_ = abi.encodePacked(m_, prevouts_, amounts_, scripts_, BtcTx.shaSequences(raw_, t_));
        }
        if (base_ != NONE && base_ != SINGLE)
            m_ = abi.encodePacked(m_, BtcTx.shaOutputs(raw_, t_));
        // spend_type = 2 * ext_flag + annex_present = 0
        m_ = abi.encodePacked(m_, uint8(0));
    }

    /// The input (whole, or its index) and, for SINGLE, its output.
    function _inputPart(
        bytes calldata raw_,
        TxView memory t_,
        Prevout[] calldata pv_,
        uint256 index_,
        uint8 hashType_
    ) private pure returns (bytes memory m_) {
        if (hashType_ & ANYONECANPAY != 0) {
            // outpoint, amount, scriptPubKey, nSequence
            uint256 o_ = BtcTx.inputOffset(t_, index_);
            m_ = abi.encodePacked(raw_[o_:o_ + 36], BtcTx.le64(pv_[index_].amount));
            m_ = abi.encodePacked(
                m_,
                BtcTx.compactSizeBytes(pv_[index_].scriptPubKey.length),
                pv_[index_].scriptPubKey
            );
            m_ = abi.encodePacked(m_, raw_[o_ + 37:o_ + 41]);
        } else {
            m_ = abi.encodePacked(BtcTx.le32(uint32(index_)));
        }
        if (hashType_ & 3 == SINGLE)
            m_ = abi.encodePacked(m_, sha256(BtcTx.outBytes(raw_, t_, index_)));
    }

    /// TapSighash = tagged_hash("TapSighash", sigMsg).
    function sigHash(
        bytes calldata raw_,
        TxView memory t_,
        Prevout[] calldata pv_,
        uint256 index_,
        uint8 hashType_
    ) internal pure returns (bytes32) {
        return sha256(abi.encodePacked(TAG, TAG, sigMsg(raw_, t_, pv_, index_, hashType_)));
    }
}
