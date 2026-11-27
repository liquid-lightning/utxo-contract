// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Mock} from "./ERC20Mock.sol";

/**
 * @notice Test-only: a fee on transfer of `feeBps`/10,000 (at least 1 unit), burned:
 * taken from what the recipient gets, or (`fromSender`) charged to the sender on top.
 */
contract FeeTokenMock is ERC20Mock {
    uint256 public feeBps;
    bool public fromSender;

    constructor() ERC20Mock(6) {}

    function setFee(uint256 feeBps_, bool fromSender_) external {
        feeBps = feeBps_;
        fromSender = fromSender_;
    }

    function _move(address from_, address to_, uint256 amount_) internal override {
        uint256 fee_ = feeBps == 0 ? 0 : (amount_ * feeBps) / 10_000 + 1;
        uint256 debit_ = fromSender ? amount_ + fee_ : amount_;

        require(balanceOf[from_] >= debit_, "balance");

        balanceOf[from_] -= debit_;
        balanceOf[to_] += debit_ - fee_;
        totalSupply -= fee_;

        emit Transfer(from_, to_, debit_ - fee_);
    }
}
