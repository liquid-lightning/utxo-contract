// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BtcTx, TxView, Prevout} from "../../../libs/bitcoin/BtcTx.sol";
import {Bip143} from "../../../libs/bitcoin/Bip143.sol";
import {TaprootSighash} from "../../../libs/bitcoin/TaprootSighash.sol";

/**
 * @notice Test-only: the signature hashes on calldata, for the official vectors.
 */
contract SighashMock {
    function tag() external pure returns (bytes32) {
        return TaprootSighash.TAG;
    }

    function bip143(
        bytes calldata rawTx_,
        uint256 index_,
        bytes calldata scriptCode_,
        uint64 amount_,
        uint8 hashType_
    ) external pure returns (bytes32) {
        TxView memory t_ = BtcTx.parse(rawTx_);

        return Bip143.sigHash(rawTx_, t_, index_, scriptCode_, amount_, hashType_);
    }

    function sigMsg(
        bytes calldata rawTx_,
        Prevout[] calldata prevouts_,
        uint256 index_,
        uint8 hashType_
    ) external pure returns (bytes memory) {
        TxView memory t_ = BtcTx.parse(rawTx_);

        return TaprootSighash.sigMsg(rawTx_, t_, prevouts_, index_, hashType_);
    }

    function sigHash(
        bytes calldata rawTx_,
        Prevout[] calldata prevouts_,
        uint256 index_,
        uint8 hashType_
    ) external pure returns (bytes32) {
        TxView memory t_ = BtcTx.parse(rawTx_);

        return TaprootSighash.sigHash(rawTx_, t_, prevouts_, index_, hashType_);
    }

    function hashes(
        bytes calldata rawTx_,
        Prevout[] calldata prevouts_
    ) external pure returns (bytes32[5] memory h_) {
        TxView memory t_ = BtcTx.parse(rawTx_);

        h_[0] = BtcTx.shaAmounts(t_, prevouts_);
        h_[1] = BtcTx.shaOutputs(rawTx_, t_);
        h_[2] = BtcTx.shaPrevouts(rawTx_, t_);
        h_[3] = BtcTx.shaScripts(t_, prevouts_);
        h_[4] = BtcTx.shaSequences(rawTx_, t_);
    }
}
