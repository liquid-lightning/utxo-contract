// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IUtxoChainBase} from "./IUtxoChainBase.sol";

/**
 * @notice The UtxoChain module
 *
 * The UTXO set holding one ERC-20 token (SPEC 4.6): 1 sat = UNITS_PER_SAT token units,
 * one instance per token. Rebasing tokens MUST NOT be used.
 */
interface IUtxoChainToken is IUtxoChainBase {
    /**
     * @notice Takes token units from the caller (approved first) and creates one output of
     * amount / UNITS_PER_SAT sats, as the output 0 of a synthetic deposit transaction (SPEC 3.3)
     * @param amount_ the token units to deposit, a multiple of UNITS_PER_SAT
     * @param scriptPubKey_ the script the output pays
     * @return txid_ the id of the deposit transaction, in internal byte order
     */
    function deposit(
        uint256 amount_,
        bytes calldata scriptPubKey_
    ) external returns (bytes32 txid_);

    /**
     * @notice The ERC-20 token this instance holds
     * @return the token's address
     */
    function TOKEN() external view returns (address);

    /**
     * @notice Token units per sat: 10^(decimals - 8), or 1 below 8 decimals
     * @return the units
     */
    function UNITS_PER_SAT() external view returns (uint256);
}
