// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply ERC-20 for an educational Sepolia demonstration only.
/// @dev This contract is not production token infrastructure.
contract SepoliaDemoERC20 is ERC20 {
    error ZeroInitialHolder();
    error ZeroInitialSupply();

    constructor(string memory name_, string memory symbol_, address initialHolder, uint256 initialSupply)
        ERC20(name_, symbol_)
    {
        if (initialHolder == address(0)) revert ZeroInitialHolder();
        if (initialSupply == 0) revert ZeroInitialSupply();

        _mint(initialHolder, initialSupply);
    }
}
