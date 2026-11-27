// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BtcTx, TxView, Prevout} from "../../libs/bitcoin/BtcTx.sol";
import {Validation} from "../../libs/bitcoin/Validation.sol";
import {UtxoChain} from "../../v1/UtxoChain.sol";

/**
 * @notice Test-only: UtxoChain plus a way to put outputs in the UTXO set directly (the
 * real vectors spend outputs of another chain's deposits), and validation without storage.
 */
contract UtxoChainMock is UtxoChain {
    constructor(uint256 interval_) UtxoChain(interval_) {}

    /// Seeds outputs, paid for with msg.value so the balance invariant holds.
    function seed(
        bytes32[] calldata txids_,
        uint32[] calldata vouts_,
        Prevout[] calldata prevouts_
    ) external payable {
        uint256 total_;

        for (uint256 i = 0; i < prevouts_.length; ++i) {
            Prevout calldata p_ = prevouts_[i];

            total_ += uint256(p_.amount) * SAT;
            utxo[utxoKey(txids_[i], vouts_[i])] = _commitment(
                p_.amount,
                p_.scriptPubKey,
                p_.height
            );
        }

        require(msg.value == total_, "seed value");
    }

    function setDepositNonce(uint256 nonce_) external {
        depositNonce = nonce_;
    }

    /// SPEC 4.3 without the UTXO set (no storage read or written).
    function validateOnly(
        bytes calldata rawTx_,
        Prevout[] calldata prevouts_
    ) external view returns (bytes32 txid_, uint256 fee_) {
        uint32 h_ = _applyHeight();
        TxView memory t_;

        (t_, fee_) = Validation.validate(rawTx_, prevouts_, h_, _mtp(h_));
        txid_ = t_.txid;
    }

    function parseOnly(bytes calldata rawTx_) external pure returns (bytes32) {
        return BtcTx.parse(rawTx_).txid;
    }

    /// SPEC 4.3 at a given height, without the UTXO set: for the checks at a
    /// height the test's clock has already passed.
    function validateAt(
        bytes calldata rawTx_,
        Prevout[] calldata prevouts_,
        uint32 height_
    ) external view returns (bytes32 txid_, uint256 fee_) {
        TxView memory t_;

        (t_, fee_) = Validation.validate(rawTx_, prevouts_, height_, _mtp(height_));
        txid_ = t_.txid;
    }
}
