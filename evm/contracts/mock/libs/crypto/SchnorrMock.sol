// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Schnorr} from "../../../libs/crypto/Schnorr.sol";

/**
 * @notice Test-only: BIP340 verification, for the official vectors.
 */
contract SchnorrMock {
    function challengeTag() external pure returns (bytes32) {
        return Schnorr.CHALLENGE_TAG;
    }

    function verify(
        bytes32 pubkeyX_,
        bytes32 msgHash_,
        uint256 rx_,
        uint256 s_
    ) external view returns (bool) {
        return Schnorr.verify(pubkeyX_, msgHash_, rx_, s_);
    }

    function verifyBytes(
        bytes32 pubkeyX_,
        bytes calldata message_,
        uint256 rx_,
        uint256 s_
    ) external view returns (bool) {
        return Schnorr.verifyBytes(pubkeyX_, message_, rx_, s_);
    }
}
