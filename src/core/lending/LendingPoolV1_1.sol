// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LendingPool} from "./LendingPool.sol";

contract LendingPoolV1_1 is LendingPool {
    function version() external pure returns (string memory) {
        return "1.1";
    }
}
