// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AUtxoChain} from "./AUtxoChain.sol";
import {IUtxoChain} from "../interfaces/v1/IUtxoChain.sol";
import {WithdrawFailed} from "../libs/utils/Errors.sol";

/// @title AUtxoChain holding ETH (SPEC 4): 1 sat = 10^10 wei.
/// `deposit` takes msg.value; `withdraw` pays with a plain call. The ABI and
/// the behaviour are those of M1's UtxoChain.
contract UtxoChain is IUtxoChain, AUtxoChain {
    uint256 internal constant SAT = 1e10; // wei per sat

    /// @param interval_ seconds per virtual block (2 on anvil, 60 on Base Sepolia)
    constructor(uint256 interval_) AUtxoChain(interval_) {}

    function _unit() internal pure override returns (uint256) {
        return SAT;
    }

    /// @notice Creates one output of msg.value / 10^10 sats paying
    /// `scriptPubKey`, as the output 0 of a synthetic deposit tx (SPEC 3.3).
    function deposit(
        bytes calldata scriptPubKey_
    ) external payable override returns (bytes32 txid_) {
        return _deposit(msg.value, scriptPubKey_);
    }

    /// The value came with the call, and `_deposit` checked it.
    function _collect(uint256) internal pure override {}

    /// A recipient that reverts gets WithdrawFailed and keeps its balance.
    function _pay(address to_, uint256 amount_) internal override {
        (bool ok_, ) = to_.call{value: amount_}("");
        if (!ok_) revert WithdrawFailed();
    }
}
