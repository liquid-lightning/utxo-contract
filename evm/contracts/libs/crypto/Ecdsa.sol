// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Secp256k1} from "./Secp256k1.sol";

/// @title Bitcoin ECDSA signatures: strict DER parsing, and verification
/// against a compressed public key with ecrecover. No hints (SPEC 4.3.10).
///
/// @notice Soundness (from spike S3, with the hints now computed on-chain):
///   1. The key's Y is computed by Secp256k1.liftX: the unique y < p with
///      y^2 = x^3 + 7 and the parity of the 02/03 prefix. A key whose x is not
///      on the curve (or >= p) is rejected, as Bitcoin does. So `expected` =
///      address(keccak256(x || y)) is the address of the key's own point P.
///   2. ecrecover(z, v, r, s) returns address(Q), Q = r^-1 * (s * R - z * G),
///      where R is the point with x = r and the y parity v - 27. If
///      address(Q) == expected then Q = P (up to a 160-bit keccak second
///      preimage), so s * R = z * G + r * P, i.e. R = s^-1 * (z * G + r * P)
///      with R.x = r: exactly ECDSA verification of (r, s) on z under P. That
///      holds for either v, so trying v = 27 and then v = 28 only decides
///      whether an honest signature is found, never whether a forged one passes.
///   3. ecrecover reduces z mod n as Bitcoin does, and rejects r, s outside
///      [1, n); we check those ranges anyway, plus low S. It returns zero for
///      an r that is not the x of a curve point and for the point at infinity
///      (true of geth and revm, so of Base and OP), and `expected` is never zero.
/// The one honest signature this rejects has R.x >= n (so r = R.x - n, and
/// ecrecover lifts the wrong point), with probability about 2^-128.
library Ecdsa {
    uint256 internal constant HALF_N = Secp256k1.N / 2;

    /// @notice Parses a Bitcoin signature: DER followed by one hash type byte.
    /// Enforces BIP66 (IsValidSignatureEncoding), 0 < r < n and 0 < s <= n/2
    /// (low S). The hash type is returned unchecked.
    function parse(
        bytes memory sig_
    ) internal pure returns (bool ok_, uint256 r_, uint256 s_, uint8 hashType_) {
        uint256 len_ = sig_.length;
        // 0x30 [total-len] 0x02 [R-len] [R] 0x02 [S-len] [S] [sighash]
        if (len_ < 9 || len_ > 73) return (false, 0, 0, 0);
        if (uint8(sig_[0]) != 0x30 || uint8(sig_[1]) != len_ - 3) return (false, 0, 0, 0);
        uint256 lenR_ = uint8(sig_[3]);
        if (5 + lenR_ >= len_) return (false, 0, 0, 0);
        uint256 lenS_ = uint8(sig_[5 + lenR_]);
        if (lenR_ + lenS_ + 7 != len_) return (false, 0, 0, 0);
        if (!_derInt(sig_, 2, lenR_) || !_derInt(sig_, lenR_ + 4, lenS_)) return (false, 0, 0, 0);
        r_ = _readInt(sig_, 4, lenR_);
        s_ = _readInt(sig_, 6 + lenR_, lenS_);
        // _readInt returns N (out of range) for integers wider than 32 bytes.
        if (r_ == 0 || r_ >= Secp256k1.N || s_ == 0 || s_ > HALF_N) return (false, 0, 0, 0);
        return (true, r_, s_, uint8(sig_[len_ - 1]));
    }

    /// @notice The point of a 33-byte compressed key: prefix 02 or 03, x < p
    /// and on the curve (see the library notes, 1).
    function liftKey(
        bytes memory pubkey_
    ) internal view returns (bool ok_, uint256 x_, uint256 y_) {
        if (pubkey_.length != 33) return (false, 0, 0);
        uint8 prefix_ = uint8(pubkey_[0]);
        if (prefix_ != 0x02 && prefix_ != 0x03) return (false, 0, 0);
        assembly ("memory-safe") {
            x_ := mload(add(pubkey_, 33))
        }
        (ok_, y_) = Secp256k1.liftX(x_, prefix_ & 1);
    }

    /// @notice True iff (r, s) is a valid ECDSA signature of `digest` by the
    /// point (x, y) from liftKey (see the library notes, 2 and 3).
    function verify(
        uint256 x_,
        uint256 y_,
        bytes32 digest_,
        uint256 r_,
        uint256 s_
    ) internal pure returns (bool) {
        address expected_ = Secp256k1.addr(x_, y_);
        if (ecrecover(digest_, 27, bytes32(r_), bytes32(s_)) == expected_) return true;
        return ecrecover(digest_, 28, bytes32(r_), bytes32(s_)) == expected_;
    }

    /// BIP66 rules for one INTEGER at sig[off] (its 0x02 tag) of length `n`:
    /// non-empty, not negative, no unnecessary leading zero byte.
    function _derInt(bytes memory sig_, uint256 off_, uint256 n_) private pure returns (bool) {
        if (uint8(sig_[off_]) != 0x02 || n_ == 0) return false;
        uint8 first_ = uint8(sig_[off_ + 2]);
        if (first_ & 0x80 != 0) return false;
        if (n_ > 1 && first_ == 0 && uint8(sig_[off_ + 3]) & 0x80 == 0) return false;
        return true;
    }

    /// Big-endian integer of n bytes at sig[off]; N if it does not fit 32 bytes.
    function _readInt(
        bytes memory sig_,
        uint256 off_,
        uint256 n_
    ) private pure returns (uint256 v_) {
        if (n_ == 33) {
            // only a leading zero byte can make a valid 33-byte INTEGER of a value < 2^256
            if (uint8(sig_[off_]) != 0) return Secp256k1.N;
            off_ += 1;
            n_ = 32;
        }
        if (n_ > 32) return Secp256k1.N;
        assembly ("memory-safe") {
            v_ := shr(mul(8, sub(32, n_)), mload(add(add(sig_, 32), off_)))
        }
    }
}
