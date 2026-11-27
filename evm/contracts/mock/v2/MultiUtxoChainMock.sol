// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TxView} from "../../libs/bitcoin/BtcTx.sol";
import {AssetPrevout} from "../../libs/elements/ElementsTx.sol";
import {ElementsValidation} from "../../libs/elements/ElementsValidation.sol";
import {MultiUtxoChain} from "../../v2/MultiUtxoChain.sol";

/**
 * @notice Test-only: MultiUtxoChain plus a way to put outputs in the UTXO set directly,
 * and validation at a given height without storage.
 */
contract MultiUtxoChainMock is MultiUtxoChain {
    constructor(
        uint256 interval_,
        bytes32 feeAsset_,
        address owner_
    ) MultiUtxoChain(interval_, feeAsset_, owner_) {}

    /// Seeds outputs. The fee asset's are paid for with msg.value; the test mints the
    /// tokens' amounts to this contract, so the balance invariant holds.
    function seed(
        bytes32[] calldata txids_,
        uint32[] calldata vouts_,
        AssetPrevout[] calldata prevouts_
    ) external payable {
        uint256 native_;

        for (uint256 i = 0; i < prevouts_.length; ++i) {
            AssetPrevout calldata p_ = prevouts_[i];
            uint256 value_ = uint256(p_.amount) * _assets[p_.asset].unitsPerSat;

            if (p_.asset == FEE_ASSET) native_ += value_;

            owed[p_.asset] += value_;
            utxo[utxoKey(txids_[i], vouts_[i])] = _commitment(
                p_.asset,
                p_.amount,
                p_.scriptPubKey,
                p_.height
            );
        }

        require(msg.value == native_, "seed value");
    }

    /// The validation at a given height, without the UTXO set: for the checks at a
    /// height the test's clock has already passed.
    function validateAt(
        bytes calldata rawTx_,
        AssetPrevout[] calldata prevouts_,
        uint32 height_
    ) external view returns (bytes32) {
        TxView memory t_ = ElementsValidation.parse(rawTx_, prevouts_);

        ElementsValidation.check(rawTx_, t_, prevouts_, height_, _mtp(height_));

        return t_.txid;
    }
}
