// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BtcTx, TxView, Stack} from "../bitcoin/BtcTx.sol";
import {Templates} from "../bitcoin/Templates.sol";
import {Validation} from "../bitcoin/Validation.sol";
import {ElementsTx, AssetPrevout} from "./ElementsTx.sol";
import {ElementsSighash} from "./ElementsSighash.sol";
import {
    PrevoutCountMismatch,
    AmountTooLarge,
    TooManySigops,
    TimeRelativeLockUnsupported,
    RelativeLockNotMet,
    UnsupportedScriptPubKey,
    AssetImbalance
} from "../utils/Errors.sol";

/// @title Whether an Elements-format transaction is valid at height h against
/// the prevouts its submitter claims, except for what needs the UTXO set
/// (each prevout's commitment in it, and no outpoint spent twice), which the
/// chain checks as it spends the inputs, between `parse` and `check`.
/// @notice The rules are Validation's (SPEC 4.3), with these differences:
/// - the amounts balance per asset, exactly: for each asset, the inputs
///   equal the outputs. A fee is an output with an empty script, so nothing
///   is left implicit;
/// - the scriptPubKeys are P2WPKH and P2WSH (no taproot: Core Lightning does
///   not use it on Elements), with the same script templates, signed over
///   the Elements signature hash.
library ElementsValidation {
    function parse(
        bytes calldata raw_,
        AssetPrevout[] calldata pv_
    ) internal pure returns (TxView memory t_) {
        t_ = ElementsTx.parse(raw_);
        if (pv_.length != t_.nIn) revert PrevoutCountMismatch();
    }

    /// @param h_ the height the tx would be applied at
    /// @param mtp_ the median time past of block h_
    function check(
        bytes calldata raw_,
        TxView memory t_,
        AssetPrevout[] calldata pv_,
        uint256 h_,
        uint256 mtp_
    ) internal view {
        _checkAmounts(raw_, t_, pv_);
        _checkSigops(raw_, t_);
        Validation.checkLockTime(raw_, t_, h_, mtp_);
        _checkRelativeLocks(raw_, t_, pv_, h_);
        _checkScripts(raw_, t_, pv_);
    }

    /// Every amount at most MAX_MONEY, and for each asset the sum of the
    /// inputs equals the sum of the outputs (fee outputs included).
    /// @dev A transaction has few assets (a channel's, and the fee asset), so
    /// they are kept in a list: no more entries than inputs, since an output
    /// in an asset no input has cannot balance.
    function _checkAmounts(
        bytes calldata raw_,
        TxView memory t_,
        AssetPrevout[] calldata pv_
    ) private pure {
        uint256 nIn_ = pv_.length;
        bytes32[] memory assets_ = new bytes32[](nIn_);
        uint256[] memory left_ = new uint256[](nIn_);
        uint256 count_;
        for (uint256 i; i < nIn_; ++i) {
            uint64 a_ = pv_[i].amount;
            if (a_ > Validation.MAX_MONEY) revert AmountTooLarge();
            bytes32 asset_ = pv_[i].asset;
            uint256 k_ = _find(assets_, count_, asset_);
            if (k_ == count_) assets_[count_++] = asset_;
            left_[k_] += a_;
            if (left_[k_] > Validation.MAX_MONEY) revert AmountTooLarge();
        }
        uint256 nOut_ = BtcTx.nOut(t_);
        for (uint256 j; j < nOut_; ++j) {
            uint64 a_ = ElementsTx.outAmount(raw_, t_, j);
            // (Core Lightning adds a fee output to every transaction, of value
            // zero when it pays no fee: it needs no input in the fee asset.)
            if (a_ == 0) continue;
            if (a_ > Validation.MAX_MONEY) revert AmountTooLarge();
            bytes32 asset_ = ElementsTx.outAsset(raw_, t_, j);
            uint256 k_ = _find(assets_, count_, asset_);
            if (k_ == count_ || left_[k_] < a_) revert AssetImbalance(asset_);
            left_[k_] -= a_;
        }
        for (uint256 k; k < count_; ++k) {
            if (left_[k] != 0) revert AssetImbalance(assets_[k]);
        }
    }

    /// The index of `asset_` among the first `count_` entries, or `count_`.
    function _find(
        bytes32[] memory assets_,
        uint256 count_,
        bytes32 asset_
    ) private pure returns (uint256 k_) {
        while (k_ < count_ && assets_[k_] != asset_) ++k_;
    }

    /// 4 * (legacy sigops in all output scripts) + 4 * (input count) <= 16,000.
    function _checkSigops(bytes calldata raw_, TxView memory t_) private pure {
        uint256 legacy_;
        uint256 n_ = BtcTx.nOut(t_);
        for (uint256 j; j < n_; ++j) {
            legacy_ += Validation.legacySigops(ElementsTx.outScript(raw_, t_, j));
        }
        if (4 * legacy_ + Validation.SIGOPS_PER_INPUT * t_.nIn > Validation.MAX_SIGOPS_COST)
            revert TooManySigops();
    }

    /// BIP68, for version >= 2: an input whose sequence has bit 31 clear is a
    /// time lock (unsupported) if bit 22 is set, and otherwise needs
    /// h - prevout.height >= sequence & 0xffff.
    function _checkRelativeLocks(
        bytes calldata raw_,
        TxView memory t_,
        AssetPrevout[] calldata pv_,
        uint256 h_
    ) private pure {
        if (t_.version < 2) return;
        for (uint256 i; i < t_.nIn; ++i) {
            uint32 seq_ = BtcTx.sequence(raw_, t_, i);
            if (seq_ & Templates.SEQ_DISABLE != 0) continue;
            if (seq_ & Templates.SEQ_TYPE != 0) revert TimeRelativeLockUnsupported(i);
            if (h_ < uint256(pv_[i].height) + (seq_ & Templates.SEQ_MASK))
                revert RelativeLockNotMet(i);
        }
    }

    /// Each input's scriptPubKey is P2WPKH or P2WSH, and its witness satisfies it.
    function _checkScripts(
        bytes calldata raw_,
        TxView memory t_,
        AssetPrevout[] calldata pv_
    ) private view {
        for (uint256 i; i < t_.nIn; ++i) {
            // Nothing allocated while checking one input is used afterwards,
            // so the memory is reused for the next input (as in Validation).
            uint256 freeMem_;
            assembly {
                freeMem_ := mload(0x40)
            }
            bytes calldata spk_ = pv_[i].scriptPubKey;
            Stack memory w_ = BtcTx.stack(raw_, t_, i);
            Templates.Input memory in_ = Templates.Input(
                i,
                pv_[i].amount,
                w_,
                ElementsSighash.sigHash
            );
            if (spk_.length == 22 && spk_[0] == 0x00 && spk_[1] == 0x14) {
                Templates.p2wpkh(raw_, t_, in_, bytes20(spk_[2:22]));
            } else if (spk_.length == 34 && spk_[0] == 0x00 && spk_[1] == 0x20) {
                Templates.p2wsh(raw_, t_, in_, bytes32(spk_[2:34]));
            } else {
                revert UnsupportedScriptPubKey(i);
            }
            assembly {
                mstore(0x40, freeMem_)
            }
        }
    }
}
