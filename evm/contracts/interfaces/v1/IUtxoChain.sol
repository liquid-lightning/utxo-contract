// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IUtxoChainBase} from "./IUtxoChainBase.sol";

/**
 * @notice The UtxoChain module
 *
 * The UTXO set holding ETH: 1 sat = 10^10 wei.
 */
interface IUtxoChain is IUtxoChainBase {
    /**
     * @notice Creates one output of msg.value / 10^10 sats, as the output 0 of a
     * synthetic deposit transaction (SPEC 3.3)
     * @param scriptPubKey_ the script the output pays
     * @return txid_ the id of the deposit transaction, in internal byte order
     */
    function deposit(bytes calldata scriptPubKey_) external payable returns (bytes32 txid_);
}
