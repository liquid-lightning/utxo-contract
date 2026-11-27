// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prevout} from "../../libs/bitcoin/BtcTx.sol";
import {IUtxoChainToken} from "../../interfaces/v1/IUtxoChainToken.sol";

import {ERC20Mock} from "../tokens/ERC20Mock.sol";

/**
 * @notice Test-only: takes a fee by submitting, then withdraws it; a hook token calls
 * back onTokenTransfer, from which it re-enters `withdraw` (or `deposit`).
 */
contract TokenReentererMock {
    IUtxoChainToken internal immutable _CHAIN;
    /// Let the inner revert through (else catch it).
    bool internal immutable _PROPAGATE;

    /// Re-enter with a deposit instead of a withdraw.
    bool public viaDeposit;
    uint256 public calls;
    bytes public innerError;

    constructor(IUtxoChainToken chain_, bool propagate_) {
        _CHAIN = chain_;
        _PROPAGATE = propagate_;
    }

    function setViaDeposit(bool viaDeposit_) external {
        viaDeposit = viaDeposit_;
    }

    function approve(ERC20Mock token_, uint256 amount_) external {
        token_.approve(address(_CHAIN), amount_);
    }

    function submit(bytes calldata rawTx_, Prevout[] calldata prevouts_) external {
        _CHAIN.submit(rawTx_, prevouts_);
    }

    function attack() external {
        _CHAIN.withdraw();
    }

    function depositFrom(uint256 amount_, bytes calldata scriptPubKey_) external {
        _CHAIN.deposit(amount_, scriptPubKey_);
    }

    function onTokenTransfer(address, address, uint256) external {
        calls += 1;

        if (calls > 1) return;

        bytes memory call_ =
            viaDeposit
                ? abi.encodeCall(
                    _CHAIN.deposit,
                    (1e10, hex"0014aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                )
                : abi.encodeCall(_CHAIN.withdraw, ());

        (bool ok_, bytes memory e_) = address(_CHAIN).call(call_);

        if (!ok_) {
            innerError = e_;

            if (_PROPAGATE) {
                assembly ("memory-safe") {
                    revert(add(e_, 32), mload(e_))
                }
            }
        }
    }
}
