// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LendingPool} from "./LendingPool.sol";

contract LendingPoolV1_1 is LendingPool {
    function version() public pure virtual returns (string memory) {
        return "1.1";
    }
}
