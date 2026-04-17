// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CollateralVault is ERC4626 {
    constructor(string memory name_, string memory symbol_, IERC20 underlyingAsset_)
        ERC20(name_, symbol_)
        ERC4626(underlyingAsset_) {}
}
