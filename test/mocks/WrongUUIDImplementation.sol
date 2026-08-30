// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";

contract WrongUUIDImplementation is IERC1822Proxiable {
    // The canonical IERC-1822 selector requires this exact spelling.
    // forge-lint: disable-next-line(mixed-case-function)
    function proxiableUUID() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}
