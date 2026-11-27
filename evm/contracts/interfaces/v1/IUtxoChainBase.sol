// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prevout} from "../../libs/bitcoin/BtcTx.sol";

/**
 * @notice The UtxoChain module
 *
 * A Bitcoin-style UTXO set held by a contract and spent by Bitcoin transactions (SPEC 4).
 * Lightning nodes use it as their chain: channels are funded, closed and enforced by
 * Bitcoin transactions that the contract validates.
 *
 * This is the part every deployable shares. The asset is left to them: `IUtxoChain`
 * holds ETH and `IUtxoChainToken` one ERC-20.
 */
interface IUtxoChainBase {
    /**
     * @notice Emitted for every deposit and every applied transaction, in the order applied
     * @param height the virtual block height the transaction was applied at
     * @param txid the transaction id, in Bitcoin's internal byte order
     * @param rawTx the transaction as submitted (for a deposit, the synthetic transaction)
     */
    event TxApplied(uint32 indexed height, bytes32 indexed txid, bytes rawTx);

    /**
     * @notice Validates a transaction against the prevouts at the current height (SPEC 4.3)
     * and applies it (SPEC 4.4). Anyone may submit any valid transaction; the fee goes to
     * the submitter's `withdrawable`
     * @param rawTx_ the serialized segwit transaction
     * @param prevouts_ the outputs the inputs spend, in input order
     * @return txid_ the transaction id, in internal byte order
     */
    function submit(
        bytes calldata rawTx_,
        Prevout[] calldata prevouts_
    ) external returns (bytes32 txid_);

    /**
     * @notice Pays the caller its `withdrawable` (exits and fees)
     */
    function withdraw() external;

    /**
     * @notice The current virtual block height: (block.timestamp - GENESIS_TIME) / INTERVAL
     * @return the height
     */
    function height() external view returns (uint32);

    /**
     * @notice Whether an output is in the UTXO set
     * @param txid_ the id of the transaction that created it, in internal byte order
     * @param vout_ its index in that transaction
     * @param amount_ its amount in sats
     * @param scriptPubKey_ its script
     * @param height_ the height it was created at
     * @return true if exactly this output is unspent
     */
    function isUnspent(
        bytes32 txid_,
        uint32 vout_,
        uint64 amount_,
        bytes calldata scriptPubKey_,
        uint32 height_
    ) external view returns (bool);

    /**
     * @notice The key of an outpoint in `utxo`
     * @param txid_ the transaction id, in internal byte order
     * @param vout_ the output index
     * @return keccak256(txid, uint32 vout)
     */
    function utxoKey(bytes32 txid_, uint32 vout_) external pure returns (bytes32);

    /**
     * @notice The time of virtual block 0 (the deployment's block timestamp)
     * @return the unix time
     */
    function GENESIS_TIME() external view returns (uint256);

    /**
     * @notice Seconds per virtual block
     * @return the interval
     */
    function INTERVAL() external view returns (uint256);

    /**
     * @notice The EVM block the contract was deployed in (where an index starts reading logs)
     * @return the block number
     */
    function DEPLOY_BLOCK() external view returns (uint256);

    /**
     * @notice The UTXO set: outpoint key => keccak256(uint64 amount, scriptPubKey, uint32 height)
     * @param key_ the outpoint key from `utxoKey`
     * @return the commitment, or zero when there is no such unspent output
     */
    function utxo(bytes32 key_) external view returns (bytes32);

    /**
     * @notice Exits and fees an address can pull with `withdraw`, in the asset's smallest units
     * @param account_ the address
     * @return the amount owed
     */
    function withdrawable(address account_) external view returns (uint256);

    /**
     * @notice The number of deposits made so far (it makes each deposit's txid unique)
     * @return the nonce the next deposit uses
     */
    function depositNonce() external view returns (uint256);

    /**
     * @notice The number of `TxApplied` events emitted so far
     * @return the count
     */
    function txCount() external view returns (uint64);

    /**
     * @notice A hash chain over the `TxApplied` events:
     * logHash = keccak256(logHash, uint32 height, txid) per event, in order (SPEC 4.1)
     * @return the current hash
     */
    function logHash() external view returns (bytes32);
}
