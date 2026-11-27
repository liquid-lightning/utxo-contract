// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prevout} from "../../libs/bitcoin/BtcTx.sol";
import {IUtxoChain} from "../../interfaces/v1/IUtxoChain.sol";

/**
 * @notice Test-only: takes a fee by submitting, then withdraws it and re-enters
 * `withdraw` from its receive function.
 */
contract ReentererMock {
    IUtxoChain internal immutable _CHAIN;
    /// Let the inner revert through (else catch it).
    bool internal immutable _PROPAGATE;

    uint256 public received;
    uint256 public calls;
    bytes public innerError;

    constructor(IUtxoChain chain_, bool propagate_) {
        _CHAIN = chain_;
        _PROPAGATE = propagate_;
    }

    receive() external payable {
        received += msg.value;
        calls += 1;

        if (calls > 1) return;

        if (_PROPAGATE) {
            _CHAIN.withdraw();
        } else {
            try _CHAIN.withdraw() {} catch (bytes memory e_) {
                innerError = e_;
            }
        }
    }

    function submit(bytes calldata rawTx_, Prevout[] calldata prevouts_) external {
        _CHAIN.submit(rawTx_, prevouts_);
    }

    function attack() external {
        _CHAIN.withdraw();
    }
}
