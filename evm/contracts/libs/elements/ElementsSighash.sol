// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BtcTx, TxView} from "../bitcoin/BtcTx.sol";
import {Bip143} from "../bitcoin/Bip143.sol";
import {ElementsTx} from "./ElementsTx.sol";

/// @title The Elements signature hash for segwit v0 inputs, for the explicit
/// transactions ElementsTx parses, and the hash types of Bip143.
/// @notice It is BIP143 with three differences (Elements' SignatureHash, as
/// libwally computes it):
/// - hashIssuance follows hashSequence: the double SHA256 of one zero byte
///   per input (no input has an issuance), and 32 zero bytes with
///   ANYONECANPAY;
/// - the spent output's value is its 9-byte explicit encoding (0x01 and 8
///   bytes, big-endian) rather than 8 bytes little-endian;
/// - hashOutputs is over the outputs as Elements serializes them (asset,
///   value, nonce, script).
/// The spent output's asset is not in the hash: the chain binds it through
/// the UTXO set, as it does the amount and the script.
library ElementsSighash {
    /// @dev hashType_ must satisfy Bip143.validHashType.
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
            bytes1(0x01),
            bytes8(amount_),
            tail_
        );
        return sha256(abi.encodePacked(sha256(preimage_)));
    }

    /// nVersion, hashPrevouts, hashSequence, hashIssuance, outpoint
    function _head(
        bytes calldata raw_,
        TxView memory t_,
        uint256 index_,
        uint8 hashType_
    ) private pure returns (bytes memory) {
        bool acp_ = hashType_ & Bip143.ANYONECANPAY != 0;
        bytes32 hashPrevouts_;
        bytes32 hashSequence_;
        bytes32 hashIssuance_;
        if (!acp_) {
            hashPrevouts_ = sha256(abi.encodePacked(BtcTx.shaPrevouts(raw_, t_)));
            hashIssuance_ = sha256(abi.encodePacked(sha256(new bytes(t_.nIn))));
        }
        if (!acp_ && hashType_ == Bip143.ALL)
            hashSequence_ = sha256(abi.encodePacked(BtcTx.shaSequences(raw_, t_)));
        uint256 o_ = BtcTx.inputOffset(t_, index_);
        return
            abi.encodePacked(
                raw_[0:4],
                hashPrevouts_,
                hashSequence_,
                hashIssuance_,
                raw_[o_:o_ + 36]
            );
    }

    /// nSequence, hashOutputs, nLockTime, nHashType
    function _tail(
        bytes calldata raw_,
        TxView memory t_,
        uint256 index_,
        uint8 hashType_
    ) private pure returns (bytes memory) {
        uint8 base_ = hashType_ & ~Bip143.ANYONECANPAY;
        bytes32 hashOutputs_;
        if (base_ == Bip143.ALL) {
            hashOutputs_ = sha256(abi.encodePacked(BtcTx.shaOutputs(raw_, t_)));
        } else if (base_ == Bip143.SINGLE && index_ < BtcTx.nOut(t_)) {
            hashOutputs_ = sha256(abi.encodePacked(sha256(BtcTx.outBytes(raw_, t_, index_))));
        }
        uint256 o_ = BtcTx.inputOffset(t_, index_);
        uint256 lock_ = ElementsTx.locktimeOffset(t_);
        return
            abi.encodePacked(
                raw_[o_ + 37:o_ + 41],
                hashOutputs_,
                raw_[lock_:lock_ + 4],
                BtcTx.le32(hashType_)
            );
    }
}
