// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BtcTx, TxView} from "../libs/bitcoin/BtcTx.sol";
import {Validation} from "../libs/bitcoin/Validation.sol";
import {ElementsTx, AssetPrevout} from "../libs/elements/ElementsTx.sol";
import {ElementsValidation} from "../libs/elements/ElementsValidation.sol";
import {
    TooEarly,
    BadInterval,
    HeightOverflow,
    BadDepositValue,
    BadDepositScript,
    NothingToWithdraw,
    WithdrawFailed,
    DuplicateInput,
    UnknownUtxo,
    BadToken,
    BadUnitsPerSat,
    TokenTransferFailed,
    TokenAmountMismatch,
    Reentrancy,
    UnknownAsset,
    AssetAlreadyRegistered,
    BadFeeAsset
} from "../libs/utils/Errors.sol";
import {IMultiUtxoChain} from "../interfaces/v2/IMultiUtxoChain.sol";
import {IERC20} from "../interfaces/tokens/IERC20.sol";

/**
 * @notice The MultiUtxoChain module
 *
 * A Bitcoin-style UTXO set of many assets, spent by Elements-format transactions.
 * Heights follow the wall clock: H(t) = (t - GENESIS_TIME) / INTERVAL.
 *
 * Invariant, for every asset: the contract's balance of it >= owed[asset], where
 * owed[asset] is the sum of the asset's UTXO amounts in its smallest units plus the sum
 * of its `withdrawable`. A deposit adds its value to both sides (the value is checked to
 * have arrived in full); a submit moves value from spent UTXOs to new UTXOs, exits and
 * fee outputs, asset by asset and exactly (an OP_RETURN amount leaves the right-hand
 * side); a withdraw lowers both by the same amount. No transaction can move value from
 * one asset to another, so a token that misbehaves can only hurt itself.
 */
contract MultiUtxoChain is IMultiUtxoChain, Ownable {
    uint256 internal constant _MAX_DEPOSIT_SCRIPT = 10_000;
    /// Wei per sat of the fee asset.
    uint256 internal constant _NATIVE_UNITS_PER_SAT = 1e10;

    uint256 public immutable override GENESIS_TIME;
    uint256 public immutable override INTERVAL;
    uint256 public immutable override DEPLOY_BLOCK;
    bytes32 public immutable override FEE_ASSET;

    mapping(bytes32 key => bytes32 commitment) public override utxo;
    mapping(address account => mapping(bytes32 asset => uint256 amount))
        public
        override withdrawable;
    mapping(bytes32 asset => uint256 amount) public override owed;
    uint256 public override depositNonce;
    uint64 public override txCount;
    bytes32 public override logHash;

    mapping(bytes32 asset => AssetInfo info) internal _assets;

    bool private transient _entered;

    /// No deposit or withdraw can run inside another's token call or payment:
    /// a token with transfer hooks can't interleave them.
    modifier nonReentrant() {
        if (_entered) revert Reentrancy();
        _entered = true;
        _;
        _entered = false;
    }

    /**
     * @param interval_ seconds per virtual block (2 on a local node, 60 on Base Sepolia)
     * @param feeAsset_ the asset tag of ETH: the fee asset of the nodes' network
     * @param owner_ who may register tokens
     */
    constructor(uint256 interval_, bytes32 feeAsset_, address owner_) Ownable(owner_) {
        if (interval_ == 0) revert BadInterval();
        if (feeAsset_ == bytes32(0)) revert BadFeeAsset();

        GENESIS_TIME = block.timestamp;
        INTERVAL = interval_;
        DEPLOY_BLOCK = block.number;
        FEE_ASSET = feeAsset_;

        _assets[feeAsset_] = AssetInfo(address(0), _NATIVE_UNITS_PER_SAT);

        emit AssetRegistered(feeAsset_, address(0), _NATIVE_UNITS_PER_SAT);
    }

    /// @inheritdoc IMultiUtxoChain
    function registerToken(
        address token_,
        uint256 unitsPerSat_
    ) external override onlyOwner returns (bytes32 asset_) {
        if (token_.code.length == 0) revert BadToken();

        try IERC20(token_).balanceOf(address(this)) returns (uint256) {} catch {
            revert BadToken();
        }

        try IERC20(token_).decimals() returns (uint8 decimals_) {
            if (unitsPerSat_ != 10 ** (decimals_ > 8 ? decimals_ - 8 : 0)) revert BadUnitsPerSat();
        } catch {
            uint256 units_ = unitsPerSat_;

            while (units_ >= 10 && units_ % 10 == 0) units_ /= 10;

            if (units_ != 1) revert BadUnitsPerSat();
        }

        if (unitsPerSat_ > 1e18) revert BadUnitsPerSat();

        asset_ = assetOf(token_);

        if (_assets[asset_].unitsPerSat != 0) revert AssetAlreadyRegistered();

        _assets[asset_] = AssetInfo(token_, unitsPerSat_);

        emit AssetRegistered(asset_, token_, unitsPerSat_);
    }

    /// @inheritdoc IMultiUtxoChain
    function depositNative(
        bytes calldata scriptPubKey_
    ) external payable override returns (bytes32 txid_) {
        return _deposit(FEE_ASSET, _assets[FEE_ASSET], msg.value, scriptPubKey_);
    }

    /// @inheritdoc IMultiUtxoChain
    function deposit(
        address token_,
        uint256 amount_,
        bytes calldata scriptPubKey_
    ) external override returns (bytes32 txid_) {
        bytes32 asset_ = assetOf(token_);
        AssetInfo memory info_ = _assets[asset_];

        if (info_.token != token_ || token_ == address(0)) revert UnknownAsset();

        return _deposit(asset_, info_, amount_, scriptPubKey_);
    }

    /// @inheritdoc IMultiUtxoChain
    function submit(
        bytes calldata rawTx_,
        AssetPrevout[] calldata prevouts_
    ) external override returns (bytes32 txid_) {
        uint32 h_ = _applyHeight();
        TxView memory t_ = ElementsValidation.parse(rawTx_, prevouts_);

        // The UTXO set first: a wrong or spent prevout fails before any
        // signature is checked. The call reverts as a whole on any failure.
        _spendInputs(rawTx_, t_, prevouts_);
        ElementsValidation.check(rawTx_, t_, prevouts_, h_, _mtp(h_));

        txid_ = t_.txid;

        _createOutputs(rawTx_, t_, h_);
        _chainLog(h_, txid_);

        emit TxApplied(h_, txid_, rawTx_);
    }

    /// @inheritdoc IMultiUtxoChain
    function withdraw(bytes32 asset_) external override nonReentrant {
        uint256 amount_ = withdrawable[msg.sender][asset_];

        if (amount_ == 0) revert NothingToWithdraw();

        withdrawable[msg.sender][asset_] = 0;
        owed[asset_] -= amount_;

        address token_ = _assets[asset_].token;

        if (token_ == address(0)) {
            (bool ok_, ) = msg.sender.call{value: amount_}("");

            if (!ok_) revert WithdrawFailed();
        } else {
            _tokenCall(
                token_,
                abi.encodeCall(IERC20.transfer, (msg.sender, amount_)),
                amount_,
                false
            );
        }
    }

    /// @inheritdoc IMultiUtxoChain
    function height() external view override returns (uint32) {
        return _height();
    }

    /// @inheritdoc IMultiUtxoChain
    function isUnspent(
        bytes32 txid_,
        uint32 vout_,
        bytes32 asset_,
        uint64 amount_,
        bytes calldata scriptPubKey_,
        uint32 height_
    ) external view override returns (bool) {
        return utxo[utxoKey(txid_, vout_)] == _commitment(asset_, amount_, scriptPubKey_, height_);
    }

    /// @inheritdoc IMultiUtxoChain
    function assetInfo(bytes32 asset_) external view override returns (AssetInfo memory) {
        return _assets[asset_];
    }

    /// @inheritdoc IMultiUtxoChain
    function utxoKey(bytes32 txid_, uint32 vout_) public pure override returns (bytes32) {
        return keccak256(abi.encodePacked(txid_, vout_));
    }

    /// @inheritdoc IMultiUtxoChain
    function assetOf(address token_) public pure override returns (bytes32 asset_) {
        // the 20 address bytes reversed, then 12 zero bytes
        uint256 v_ = uint160(token_);

        for (uint256 i = 0; i < 20; ++i) {
            asset_ |= bytes32((v_ >> (8 * i)) & 0xff) << (248 - 8 * i);
        }
    }

    /**
     * @dev Takes `value_` of the asset's smallest units and creates one output of
     * value / unitsPerSat sats paying `scriptPubKey_`, as the output 0 of a synthetic
     * deposit transaction in Elements format.
     */
    function _deposit(
        bytes32 asset_,
        AssetInfo memory info_,
        uint256 value_,
        bytes calldata scriptPubKey_
    ) internal nonReentrant returns (bytes32 txid_) {
        uint32 h_ = _applyHeight();
        uint256 unit_ = info_.unitsPerSat;

        if (value_ % unit_ != 0 || value_ < unit_ || value_ / unit_ > Validation.MAX_MONEY) {
            revert BadDepositValue();
        }

        // An empty script would be a fee output, which is never stored.
        if (
            scriptPubKey_.length == 0 ||
            scriptPubKey_.length > _MAX_DEPOSIT_SCRIPT ||
            _isExit(scriptPubKey_) ||
            _isOpReturn(scriptPubKey_)
        ) {
            revert BadDepositScript();
        }

        if (info_.token != address(0)) {
            _tokenCall(
                info_.token,
                abi.encodeCall(IERC20.transferFrom, (msg.sender, address(this), value_)),
                value_,
                true
            );
        }

        uint64 amount_ = uint64(value_ / unit_);

        // A prevout that is never in the UTXO set (so the tx cannot be
        // replayed), with the issuance and peg-in bits clear.
        bytes32 prev_ = keccak256(
            abi.encodePacked("evmchan deposit v2", block.chainid, address(this), depositNonce)
        );
        // version 2, flag 0 (no witness), 1 input (prev:0, empty scriptSig,
        // sequence 0xffffffff), 1 explicit output, locktime 0
        bytes memory rawTx_ = abi.encodePacked(
            hex"020000000001",
            prev_,
            hex"0000000000ffffffff0101",
            asset_,
            hex"01",
            amount_,
            hex"00",
            BtcTx.compactSizeBytes(scriptPubKey_.length),
            scriptPubKey_,
            hex"00000000"
        );

        txid_ = sha256(abi.encodePacked(sha256(rawTx_)));

        depositNonce += 1;
        owed[asset_] += value_;
        utxo[utxoKey(txid_, 0)] = _commitment(asset_, amount_, scriptPubKey_, h_);

        _chainLog(h_, txid_);

        emit TxApplied(h_, txid_, rawTx_);
    }

    /**
     * @dev Deletes each input's UTXO, after checking it is the prevout's commitment.
     * Deleting as we go also rejects an outpoint spent twice in the tx: its second
     * occurrence finds no UTXO.
     */
    function _spendInputs(
        bytes calldata raw_,
        TxView memory t_,
        AssetPrevout[] calldata pv_
    ) internal {
        for (uint256 i = 0; i < t_.nIn; ++i) {
            bytes32 txid_ = BtcTx.prevTxid(raw_, t_, i);
            uint32 vout_ = BtcTx.prevVout(raw_, t_, i);
            bytes32 key_ = utxoKey(txid_, vout_);

            if (
                utxo[key_] !=
                _commitment(pv_[i].asset, pv_[i].amount, pv_[i].scriptPubKey, pv_[i].height)
            ) {
                for (uint256 j = 0; j < i; ++j) {
                    if (
                        BtcTx.prevTxid(raw_, t_, j) == txid_ &&
                        BtcTx.prevVout(raw_, t_, j) == vout_
                    ) {
                        revert DuplicateInput(i);
                    }
                }

                revert UnknownUtxo(i);
            }

            delete utxo[key_];
        }
    }

    /**
     * @dev Stores each output, except fee outputs (an empty script: credited to the
     * submitter), exits (credited to their address) and OP_RETURN outputs (burned).
     * An output's key cannot already be in use: txids are unique, since a tx spends at
     * least one UTXO, which no other valid tx can spend again, and a deposit's txid
     * commits to a fresh nonce.
     */
    function _createOutputs(bytes calldata raw_, TxView memory t_, uint32 h_) internal {
        uint256 n_ = BtcTx.nOut(t_);

        for (uint256 j = 0; j < n_; ++j) {
            bytes32 asset_ = ElementsTx.outAsset(raw_, t_, j);
            uint64 amount_ = ElementsTx.outAmount(raw_, t_, j);
            bytes calldata spk_ = ElementsTx.outScript(raw_, t_, j);

            if (spk_.length == 0) {
                if (amount_ != 0) {
                    withdrawable[msg.sender][asset_] += amount_ * _assets[asset_].unitsPerSat;
                }
            } else if (_isExit(spk_)) {
                withdrawable[address(bytes20(spk_[2:22]))][asset_] +=
                    amount_ * _assets[asset_].unitsPerSat;
            } else if (_isOpReturn(spk_)) {
                owed[asset_] -= amount_ * _assets[asset_].unitsPerSat;
            } else {
                utxo[utxoKey(t_.txid, uint32(j))] = _commitment(asset_, amount_, spk_, h_);
            }
        }
    }

    /**
     * @dev Calls the token, and checks the call moved exactly `amount_` into
     * (`incoming_`) or out of this contract: fee-on-transfer tokens are refused.
     * Tokens that return no bool (USDT) are accepted.
     */
    function _tokenCall(
        address token_,
        bytes memory data_,
        uint256 amount_,
        bool incoming_
    ) internal {
        uint256 before_ = IERC20(token_).balanceOf(address(this));

        (bool ok_, bytes memory result_) = token_.call(data_);

        // No return data is a success (USDT); else it must be a true bool.
        if (
            !ok_ ||
            (result_.length != 0 && (result_.length != 32 || abi.decode(result_, (uint256)) != 1))
        ) {
            revert TokenTransferFailed();
        }

        uint256 after_ = IERC20(token_).balanceOf(address(this));

        if (
            incoming_
                ? after_ < before_ || after_ - before_ != amount_
                : after_ > before_ || before_ - after_ != amount_
        ) {
            revert TokenAmountMismatch();
        }
    }

    /// @dev Counts the event and extends the log hash, just before every TxApplied.
    function _chainLog(uint32 h_, bytes32 txid_) internal {
        txCount += 1;
        logHash = keccak256(abi.encodePacked(logHash, h_, txid_));
    }

    function _height() internal view returns (uint32) {
        uint256 h_ = (block.timestamp - GENESIS_TIME) / INTERVAL;

        if (h_ > type(uint32).max) revert HeightOverflow();

        return uint32(h_);
    }

    /// @dev The height a deposit or submit applies at; nothing is applied at 0.
    function _applyHeight() internal view returns (uint32 h_) {
        h_ = _height();

        if (h_ == 0) revert TooEarly();
    }

    /// @dev MTP(h) = T(max(h - 6, 0)), as in v1 (SPEC 4.3.5).
    function _mtp(uint32 h_) internal view returns (uint256) {
        return GENESIS_TIME + (h_ > 6 ? uint256(h_) - 6 : 0) * INTERVAL;
    }

    function _commitment(
        bytes32 asset_,
        uint64 amount_,
        bytes calldata scriptPubKey_,
        uint32 h_
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(asset_, amount_, scriptPubKey_, h_));
    }

    /// @dev Segwit v16 with a 20-byte program: `6014<20 bytes>`.
    function _isExit(bytes calldata spk_) internal pure returns (bool) {
        return spk_.length == 22 && spk_[0] == 0x60 && spk_[1] == 0x14;
    }

    function _isOpReturn(bytes calldata spk_) internal pure returns (bool) {
        return spk_.length != 0 && spk_[0] == 0x6a;
    }
}
