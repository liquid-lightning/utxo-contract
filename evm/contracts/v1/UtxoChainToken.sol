// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AUtxoChain} from "./AUtxoChain.sol";
import {IUtxoChainToken} from "../interfaces/v1/IUtxoChainToken.sol";
import {IERC20} from "../interfaces/tokens/IERC20.sol";
import {
    BadToken,
    BadUnitsPerSat,
    TokenTransferFailed,
    TokenAmountMismatch,
    Reentrancy
} from "../libs/utils/Errors.sol";

/// @title AUtxoChain holding one ERC-20 token (SPEC 4.6): 1 sat =
/// UNITS_PER_SAT token units, one instance per token.
///
/// - `deposit(amount, script)` takes `amount` units with `transferFrom` (the
///   depositor approves first); it is not payable.
/// - `withdraw()` pays with `transfer`.
/// - Tokens that return no bool (USDT) are accepted; a call that reverts or
///   returns false fails with TokenTransferFailed.
/// - Every token call must move exactly the amount: the contract's balance
///   is read before and after, and TokenAmountMismatch refuses
///   fee-on-transfer tokens and balances that change during the call.
/// - No deposit or withdraw can run inside another's token call (Reentrancy):
///   a token with transfer hooks can't interleave them.
/// Rebasing tokens break the invariant between calls, where no check can see
/// it, so they MUST NOT be used (SPEC 4.6).
contract UtxoChainToken is IUtxoChainToken, AUtxoChain {
    /// The token, and its units per sat.
    address public immutable override TOKEN;
    uint256 public immutable override UNITS_PER_SAT;

    bool private transient entered;

    /// @param interval_ seconds per virtual block (2 on anvil, 60 on Base Sepolia)
    /// @param token_ the ERC-20: it must have code and answer balanceOf
    /// @param unitsPerSat_ token units per sat (SPEC 4.6): 10^(decimals - 8)
    ///        for a token with at least 8 decimals, else 1. A token without
    ///        decimals() may take any power of ten up to 10^18.
    constructor(uint256 interval_, address token_, uint256 unitsPerSat_) AUtxoChain(interval_) {
        if (token_.code.length == 0) revert BadToken();
        try IERC20(token_).balanceOf(address(this)) returns (uint256) {} catch {
            revert BadToken();
        }
        try IERC20(token_).decimals() returns (uint8 d_) {
            if (unitsPerSat_ != 10 ** (d_ > 8 ? d_ - 8 : 0)) revert BadUnitsPerSat();
        } catch {
            uint256 u_ = unitsPerSat_;
            while (u_ >= 10 && u_ % 10 == 0) u_ /= 10;
            if (u_ != 1) revert BadUnitsPerSat();
        }
        if (unitsPerSat_ > 1e18) revert BadUnitsPerSat();
        TOKEN = token_;
        UNITS_PER_SAT = unitsPerSat_;
    }

    function _unit() internal view override returns (uint256) {
        return UNITS_PER_SAT;
    }

    /// @notice Takes `amount` token units from msg.sender (approved first) and
    /// creates one output of amount / UNITS_PER_SAT sats paying
    /// `scriptPubKey`, as the output 0 of a synthetic deposit tx (SPEC 3.3).
    function deposit(
        uint256 amount_,
        bytes calldata scriptPubKey_
    ) external override returns (bytes32 txid_) {
        return _deposit(amount_, scriptPubKey_);
    }

    function _collect(uint256 value_) internal override {
        _tokenCall(
            abi.encodeCall(IERC20.transferFrom, (msg.sender, address(this), value_)),
            value_,
            true
        );
    }

    function _pay(address to_, uint256 amount_) internal override {
        _tokenCall(abi.encodeCall(IERC20.transfer, (to_, amount_)), amount_, false);
    }

    /// Calls the token, under the lock, and checks the call moved exactly
    /// `amount` into (`incoming`) or out of this contract.
    function _tokenCall(bytes memory data_, uint256 amount_, bool incoming_) private {
        if (entered) revert Reentrancy();
        entered = true;
        uint256 before_ = IERC20(TOKEN).balanceOf(address(this));
        (bool ok_, bytes memory ret_) = TOKEN.call(data_);
        // No return data is a success (USDT); else it must be a true bool.
        if (
            !ok_ || (ret_.length != 0 && (ret_.length != 32 || abi.decode(ret_, (uint256)) != 1))
        ) {
            revert TokenTransferFailed();
        }
        uint256 now_ = IERC20(TOKEN).balanceOf(address(this));
        if (
            incoming_
                ? now_ < before_ || now_ - before_ != amount_
                : now_ > before_ || before_ - now_ != amount_
        ) {
            revert TokenAmountMismatch();
        }
        entered = false;
    }
}
