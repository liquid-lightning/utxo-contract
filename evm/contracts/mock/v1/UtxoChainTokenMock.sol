// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TxView, Prevout} from "../../libs/bitcoin/BtcTx.sol";
import {Validation} from "../../libs/bitcoin/Validation.sol";
import {UtxoChainToken} from "../../v1/UtxoChainToken.sol";

/**
 * @notice Test-only: UtxoChainToken plus `seed`. The test mints a seeded output's amount
 * to this contract, so the balance invariant holds.
 */
contract UtxoChainTokenMock is UtxoChainToken {
    constructor(
        uint256 interval_,
        address token_,
        uint256 unitsPerSat_
    ) UtxoChainToken(interval_, token_, unitsPerSat_) {}

    function seed(
        bytes32[] calldata txids_,
        uint32[] calldata vouts_,
        Prevout[] calldata prevouts_
    ) external {
        for (uint256 i = 0; i < prevouts_.length; ++i) {
            Prevout calldata p_ = prevouts_[i];

            utxo[utxoKey(txids_[i], vouts_[i])] = _commitment(
                p_.amount,
                p_.scriptPubKey,
                p_.height
            );
        }
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
