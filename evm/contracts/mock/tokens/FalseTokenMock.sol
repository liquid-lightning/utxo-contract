// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Mock} from "./ERC20Mock.sol";

/**
 * @notice Test-only: returns false (moving nothing) once `failing` is set, or a
 * malformed return value (two words) once `malformed` is set.
 */
contract FalseTokenMock is ERC20Mock {
    bool public failing;
    bool public malformed;

    constructor() ERC20Mock(6) {}

    function set(bool failing_, bool malformed_) external {
        failing = failing_;
        malformed = malformed_;
    }

    function transfer(address to_, uint256 amount_) external override returns (bool) {
        return _maybe(msg.sender, to_, amount_);
    }

    function transferFrom(
        address from_,
        address to_,
        uint256 amount_
    ) external override returns (bool) {
        if (failing) return false;

        _spend(from_, amount_);

        return _maybe(from_, to_, amount_);
    }

    function _maybe(address from_, address to_, uint256 amount_) internal returns (bool) {
        if (failing) return false;

        _move(from_, to_, amount_);

        if (malformed) {
            assembly ("memory-safe") {
                mstore(0, 1)
                mstore(32, 1)
                return(0, 64)
            }
        }

        return true;
    }
}
