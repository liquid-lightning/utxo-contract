// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Secp256k1} from "../../../libs/crypto/Secp256k1.sol";

/**
 * @notice Test-only: the on-chain point decompression.
 */
contract Secp256k1Mock {
    function liftX(uint256 x_, uint256 parity_) external view returns (bool ok_, uint256 y_) {
        return Secp256k1.liftX(x_, parity_);
    }
}
