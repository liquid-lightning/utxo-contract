// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Mock} from "./ERC20Mock.sol";

/**
 * @notice Test-only: USDT-style, transfer and transferFrom return nothing.
 */
contract NoBoolTokenMock is ERC20Mock {
    constructor() ERC20Mock(6) {}

    function transfer(address to_, uint256 amount_) external override returns (bool) {
        _move(msg.sender, to_, amount_);

        assembly ("memory-safe") {
            return(0, 0)
        }
    }

    function transferFrom(
        address from_,
        address to_,
        uint256 amount_
    ) external override returns (bool) {
        _spend(from_, amount_);
        _move(from_, to_, amount_);

        assembly ("memory-safe") {
            return(0, 0)
        }
    }
}
