// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AssetPrevout} from "../../libs/elements/ElementsTx.sol";
import {IMultiUtxoChain} from "../../interfaces/v2/IMultiUtxoChain.sol";

import {ERC20Mock} from "../tokens/ERC20Mock.sol";

/**
 * @notice Test-only: takes a transaction's fees by submitting it, then withdraws one
 * asset and, when it is paid (in ETH, or by a hook token's callback), re-enters the
 * chain with a withdraw of another asset or with a deposit.
 */
contract MultiReentererMock {
    enum Reentry {
        None,
        Withdraw,
        DepositNative,
        Deposit
    }

    IMultiUtxoChain internal immutable _CHAIN;

    Reentry public reentry;
    /// The asset of the inner withdraw, or the token of the inner deposit.
    bytes32 public reentryTarget;
    /// Let the inner revert through (else catch it).
    bool public propagate;
    uint256 public calls;
    bytes public innerError;

    constructor(IMultiUtxoChain chain_) {
        _CHAIN = chain_;
    }

    receive() external payable {
        _reenter();
    }

    function set(Reentry reentry_, bytes32 target_, bool propagate_) external {
        reentry = reentry_;
        reentryTarget = target_;
        propagate = propagate_;
    }

    function approve(ERC20Mock token_, uint256 amount_) external {
        token_.approve(address(_CHAIN), amount_);
    }

    function submit(bytes calldata rawTx_, AssetPrevout[] calldata prevouts_) external {
        _CHAIN.submit(rawTx_, prevouts_);
    }

    function withdraw(bytes32 asset_) external {
        _CHAIN.withdraw(asset_);
    }

    function depositFrom(address token_, uint256 amount_, bytes calldata scriptPubKey_) external {
        _CHAIN.deposit(token_, amount_, scriptPubKey_);
    }

    function onTokenTransfer(address, address, uint256) external {
        _reenter();
    }

    function _reenter() internal {
        calls += 1;

        if (calls > 1 || reentry == Reentry.None) return;

        bytes memory script_ = hex"0014aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        bytes memory call_;
        uint256 value_;

        if (reentry == Reentry.Withdraw) {
            call_ = abi.encodeCall(_CHAIN.withdraw, (reentryTarget));
        } else if (reentry == Reentry.DepositNative) {
            call_ = abi.encodeCall(_CHAIN.depositNative, (script_));
            value_ = 1e10;
        } else {
            call_ = abi.encodeCall(
                _CHAIN.deposit,
                (address(uint160(uint256(reentryTarget))), 1e10, script_)
            );
        }

        (bool ok_, bytes memory e_) = address(_CHAIN).call{value: value_}(call_);

        if (!ok_) {
            innerError = e_;

            if (propagate) {
                assembly ("memory-safe") {
                    revert(add(e_, 32), mload(e_))
                }
            }
        }
    }
}
