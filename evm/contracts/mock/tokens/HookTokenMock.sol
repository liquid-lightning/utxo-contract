// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Mock} from "./ERC20Mock.sol";

/**
 * @notice Test-only: ERC-777-style hooks. After moving the balance, it calls
 * onTokenTransfer(from, to, amount) on the sender (for transferFrom) and on the
 * recipient, when they have code. A hook that reverts with data reverts the transfer;
 * one without the function is ignored.
 */
contract HookTokenMock is ERC20Mock {
    constructor() ERC20Mock(18) {}

    function transfer(address to_, uint256 amount_) external override returns (bool) {
        _move(msg.sender, to_, amount_);
        _hook(to_, msg.sender, to_, amount_);

        return true;
    }

    function transferFrom(
        address from_,
        address to_,
        uint256 amount_
    ) external override returns (bool) {
        _spend(from_, amount_);
        _move(from_, to_, amount_);
        _hook(from_, from_, to_, amount_);
        _hook(to_, from_, to_, amount_);

        return true;
    }

    function _hook(address who_, address from_, address to_, uint256 amount_) internal {
        if (who_.code.length == 0) return;

        (bool ok_, bytes memory result_) = who_.call(
            abi.encodeWithSignature(
                "onTokenTransfer(address,address,uint256)",
                from_,
                to_,
                amount_
            )
        );

        if (!ok_ && result_.length != 0) {
            assembly ("memory-safe") {
                revert(add(result_, 32), mload(result_))
            }
        }
    }
}
