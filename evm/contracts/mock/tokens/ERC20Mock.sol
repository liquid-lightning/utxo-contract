// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @notice Test-only: a standard ERC-20 with configurable decimals that mints freely
 * (no dependencies). The other token mocks change one thing about it.
 */
contract ERC20Mock {
    uint8 public immutable decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to_, uint256 amount_) external {
        totalSupply += amount_;
        balanceOf[to_] += amount_;

        emit Transfer(address(0), to_, amount_);
    }

    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;

        emit Approval(msg.sender, spender_, amount_);

        return true;
    }

    function transfer(address to_, uint256 amount_) external virtual returns (bool) {
        _move(msg.sender, to_, amount_);

        return true;
    }

    function transferFrom(
        address from_,
        address to_,
        uint256 amount_
    ) external virtual returns (bool) {
        _spend(from_, amount_);
        _move(from_, to_, amount_);

        return true;
    }

    function _spend(address from_, uint256 amount_) internal {
        uint256 allowed_ = allowance[from_][msg.sender];

        require(allowed_ >= amount_, "allowance");

        if (allowed_ != type(uint256).max) allowance[from_][msg.sender] = allowed_ - amount_;
    }

    function _move(address from_, address to_, uint256 amount_) internal virtual {
        require(balanceOf[from_] >= amount_, "balance");

        balanceOf[from_] -= amount_;
        balanceOf[to_] += amount_;

        emit Transfer(from_, to_, amount_);
    }
}
