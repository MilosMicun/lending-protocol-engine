// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";

contract WrongUUIDImplementation is IERC1822Proxiable {
    function proxiableUUID() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}
