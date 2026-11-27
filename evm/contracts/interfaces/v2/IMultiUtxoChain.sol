// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AssetPrevout} from "../../libs/elements/ElementsTx.sol";

/**
 * @notice The MultiUtxoChain module
 *
 * A UTXO set that holds ETH and many ERC-20 tokens in one contract, spent by
 * Elements-format transactions: every output carries the asset it holds, as on Liquid.
 * Lightning nodes use it as a Liquid-type chain, so one node can keep channels in
 * several tokens.
 *
 * Assets. An asset is named by the 32 bytes of its explicit asset tag, as they are
 * serialized in a transaction. ETH is the fee asset (`FEE_ASSET`, the tag of the
 * Liquid-type network's native coin); a token's asset is its address, zero-padded to 32
 * bytes and byte-reversed (so the asset id that Elements tools print is the padded
 * address). Tokens are registered by the owner.
 *
 * Transactions are the explicit subset of Elements': no confidential outputs, no
 * issuances and no peg-ins. For each asset the inputs equal the outputs, and a fee is an
 * output with an empty script, credited to whoever submits the transaction.
 */
interface IMultiUtxoChain {
    /**
     * @notice What the chain knows about a registered asset
     * @param token the ERC-20, or the zero address for ETH
     * @param unitsPerSat the asset's smallest units per sat; zero if the asset is unknown
     */
    struct AssetInfo {
        address token;
        uint256 unitsPerSat;
    }

    /**
     * @notice Emitted for every deposit and every applied transaction, in the order applied
     * @param height the virtual block height the transaction was applied at
     * @param txid the transaction id, in internal byte order
     * @param rawTx the transaction as submitted (for a deposit, the synthetic transaction)
     */
    event TxApplied(uint32 indexed height, bytes32 indexed txid, bytes rawTx);

    /**
     * @notice Emitted when the owner registers a token
     * @param asset the asset tag transactions use for it
     * @param token the ERC-20
     * @param unitsPerSat token units per sat
     */
    event AssetRegistered(bytes32 indexed asset, address indexed token, uint256 unitsPerSat);

    /**
     * @notice Registers an ERC-20 as an asset. Only the owner can call it. Rebasing
     * tokens, and tokens that can start charging a transfer fee, MUST NOT be registered
     * @param token_ the ERC-20: it must have code and answer balanceOf
     * @param unitsPerSat_ token units per sat: 10^(decimals - 8), or 1 below 8 decimals.
     * A token without decimals() may take any power of ten up to 10^18
     * @return asset_ the asset tag of the token
     */
    function registerToken(address token_, uint256 unitsPerSat_) external returns (bytes32 asset_);

    /**
     * @notice Creates one output of msg.value / 10^10 sats of the fee asset, as the output 0
     * of a synthetic deposit transaction
     * @param scriptPubKey_ the script the output pays
     * @return txid_ the id of the deposit transaction, in internal byte order
     */
    function depositNative(bytes calldata scriptPubKey_) external payable returns (bytes32 txid_);

    /**
     * @notice Takes token units from the caller (approved first) and creates one output of
     * amount / unitsPerSat sats of the token's asset, as the output 0 of a synthetic deposit
     * transaction
     * @param token_ a registered ERC-20
     * @param amount_ the token units to deposit, a multiple of the token's units per sat
     * @param scriptPubKey_ the script the output pays
     * @return txid_ the id of the deposit transaction, in internal byte order
     */
    function deposit(
        address token_,
        uint256 amount_,
        bytes calldata scriptPubKey_
    ) external returns (bytes32 txid_);

    /**
     * @notice Validates an Elements-format transaction against the prevouts at the current
     * height and applies it. Anyone may submit any valid transaction; its fee outputs go to
     * the submitter's `withdrawable`
     * @param rawTx_ the serialized transaction
     * @param prevouts_ the outputs the inputs spend, in input order
     * @return txid_ the transaction id, in internal byte order
     */
    function submit(
        bytes calldata rawTx_,
        AssetPrevout[] calldata prevouts_
    ) external returns (bytes32 txid_);

    /**
     * @notice Pays the caller its `withdrawable` of one asset (exits and fees)
     * @param asset_ the asset tag
     */
    function withdraw(bytes32 asset_) external;

    /**
     * @notice The current virtual block height: (block.timestamp - GENESIS_TIME) / INTERVAL
     * @return the height
     */
    function height() external view returns (uint32);

    /**
     * @notice Whether an output is in the UTXO set
     * @param txid_ the id of the transaction that created it, in internal byte order
     * @param vout_ its index in that transaction
     * @param asset_ its asset tag
     * @param amount_ its amount in sats
     * @param scriptPubKey_ its script
     * @param height_ the height it was created at
     * @return true if exactly this output is unspent
     */
    function isUnspent(
        bytes32 txid_,
        uint32 vout_,
        bytes32 asset_,
        uint64 amount_,
        bytes calldata scriptPubKey_,
        uint32 height_
    ) external view returns (bool);

    /**
     * @notice The token and the units per sat of an asset
     * @param asset_ the asset tag
     * @return the asset's info; `unitsPerSat` is zero if the asset is not registered
     */
    function assetInfo(bytes32 asset_) external view returns (AssetInfo memory);

    /**
     * @notice The key of an outpoint in `utxo`
     * @param txid_ the transaction id, in internal byte order
     * @param vout_ the output index
     * @return keccak256(txid, uint32 vout)
     */
    function utxoKey(bytes32 txid_, uint32 vout_) external pure returns (bytes32);

    /**
     * @notice The asset tag a token gets: its address, zero-padded to 32 bytes and
     * byte-reversed
     * @param token_ the ERC-20
     * @return the asset tag
     */
    function assetOf(address token_) external pure returns (bytes32);

    /**
     * @notice The asset tag of ETH: the fee asset of the Liquid-type network the nodes run
     * @return the asset tag
     */
    function FEE_ASSET() external view returns (bytes32);

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
     * @notice The UTXO set: outpoint key =>
     * keccak256(asset, uint64 amount, scriptPubKey, uint32 height)
     * @param key_ the outpoint key from `utxoKey`
     * @return the commitment, or zero when there is no such unspent output
     */
    function utxo(bytes32 key_) external view returns (bytes32);

    /**
     * @notice Exits and fees an address can pull with `withdraw`, per asset, in the
     * asset's smallest units
     * @param account_ the address
     * @param asset_ the asset tag
     * @return the amount owed
     */
    function withdrawable(address account_, bytes32 asset_) external view returns (uint256);

    /**
     * @notice What the chain owes in an asset: its UTXOs and its `withdrawable`, in the
     * asset's smallest units. The contract's balance of the asset is at least this
     * @param asset_ the asset tag
     * @return the amount owed
     */
    function owed(bytes32 asset_) external view returns (uint256);

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
     * logHash = keccak256(logHash, uint32 height, txid) per event, in order
     * @return the current hash
     */
    function logHash() external view returns (bytes32);
}
