// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BtcTx, TxView} from "./BtcTx.sol";

/// @title BIP143 signature hash (segwit v0) for ALL, NONE, SINGLE and their
/// ANYONECANPAY variants (SPEC 4.3.8).
/// @notice Only the six defined hash types are accepted (Bitcoin's STRICTENC
/// policy; consensus would also accept undefined ones).
///
/// SINGLE when the input has no output of the same index: BIP143 (and Bitcoin
/// Core's SignatureHash for witness v0) uses a hashOutputs of 32 zero bytes, so
/// the signature commits to no output. It does NOT have the legacy "hash = 1"
/// bug: the signature still commits to this input's outpoint, amount, script
/// and sequence. We follow BIP143 exactly, as SPEC 4.3.8 says; such a
/// signature only ever spends what its own signer chose to give away. CLN
/// never makes one.
///
/// The outputs are hashed straight from the raw tx, where they lie contiguous;
/// the outpoints and sequences are gathered from it (BtcTx).
library Bip143 {
    uint8 internal constant ALL = 0x01;
    uint8 internal constant NONE = 0x02;
    uint8 internal constant SINGLE = 0x03;
    uint8 internal constant ANYONECANPAY = 0x80;

    function validHashType(uint8 hashType_) internal pure returns (bool) {
        uint8 base_ = hashType_ & ~ANYONECANPAY;
        return base_ >= ALL && base_ <= SINGLE;
    }

    /// @dev hashType must satisfy validHashType.
    function sigHash(
        bytes calldata raw_,
        TxView memory t_,
        uint256 index_,
        bytes memory scriptCode_,
        uint64 amount_,
        uint8 hashType_
    ) internal pure returns (bytes32) {
        bytes memory head_ = _head(raw_, t_, index_, hashType_);
        bytes memory tail_ = _tail(raw_, t_, index_, hashType_);
        bytes memory preimage_ = abi.encodePacked(
            head_,
            BtcTx.compactSizeBytes(scriptCode_.length),
            scriptCode_,
            BtcTx.le64(amount_),
            tail_
        );
        return sha256(abi.encodePacked(sha256(preimage_)));
    }

    /// nVersion, hashPrevouts, hashSequence, outpoint
    function _head(
        bytes calldata raw_,
        TxView memory t_,
        uint256 index_,
        uint8 hashType_
    ) private pure returns (bytes memory) {
        bool acp_ = hashType_ & ANYONECANPAY != 0;
        bytes32 hashPrevouts_;
        bytes32 hashSequence_;
        if (!acp_) hashPrevouts_ = sha256(abi.encodePacked(BtcTx.shaPrevouts(raw_, t_)));
        if (!acp_ && hashType_ == ALL)
            hashSequence_ = sha256(abi.encodePacked(BtcTx.shaSequences(raw_, t_)));
        uint256 o_ = BtcTx.inputOffset(t_, index_);
        return abi.encodePacked(raw_[0:4], hashPrevouts_, hashSequence_, raw_[o_:o_ + 36]);
    }

    /// nSequence, hashOutputs, nLockTime, nHashType
    function _tail(
        bytes calldata raw_,
        TxView memory t_,
        uint256 index_,
        uint8 hashType_
    ) private pure returns (bytes memory) {
        uint8 base_ = hashType_ & ~ANYONECANPAY;
        bytes32 hashOutputs_;
        if (base_ == ALL) {
            hashOutputs_ = sha256(abi.encodePacked(BtcTx.shaOutputs(raw_, t_)));
        } else if (base_ == SINGLE && index_ < BtcTx.nOut(t_)) {
            hashOutputs_ = sha256(abi.encodePacked(sha256(BtcTx.outBytes(raw_, t_, index_))));
        }
        uint256 o_ = BtcTx.inputOffset(t_, index_);
        return
            abi.encodePacked(
                raw_[o_ + 37:o_ + 41],
                hashOutputs_,
                raw_[raw_.length - 4:raw_.length],
                BtcTx.le32(hashType_)
            );
    }
}
