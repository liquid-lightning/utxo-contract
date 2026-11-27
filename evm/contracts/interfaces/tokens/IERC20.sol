// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @notice The part of ERC-20 that UtxoChainToken calls
 */
interface IERC20 {
    function transfer(address to_, uint256 amount_) external returns (bool);

    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool);

    function balanceOf(address who_) external view returns (uint256);

    function decimals() external view returns (uint8);
}
