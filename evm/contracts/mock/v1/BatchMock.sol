// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prevout} from "../../libs/bitcoin/BtcTx.sol";
import {IUtxoChainToken} from "../../interfaces/v1/IUtxoChainToken.sol";

import {ERC20Mock} from "../tokens/ERC20Mock.sol";

/**
 * @notice Test-only: several deposits and a withdraw in one EVM transaction (the lock is
 * released after each token call).
 */
contract BatchMock {
    function run(IUtxoChainToken chain_, ERC20Mock token_, bytes calldata scriptPubKey_) external {
        uint256 unit_ = chain_.UNITS_PER_SAT();

        token_.approve(address(chain_), type(uint256).max);
        chain_.deposit(unit_, scriptPubKey_);
        chain_.deposit(2 * unit_, scriptPubKey_);
        chain_.withdraw();
        chain_.deposit(3 * unit_, scriptPubKey_);
    }

    function submit(
        IUtxoChainToken chain_,
        bytes calldata rawTx_,
        Prevout[] calldata prevouts_
    ) external {
        chain_.submit(rawTx_, prevouts_);
    }
}
