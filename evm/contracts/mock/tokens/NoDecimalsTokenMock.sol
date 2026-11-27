// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @notice Test-only: a token without decimals() (it is optional in ERC-20).
 */
contract NoDecimalsTokenMock {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}
