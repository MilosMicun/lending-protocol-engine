// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceFeed} from "../interfaces/IPriceFeed.sol";

library OracleLib {
    uint256 private constant WAD = 1e18;

    error InvalidPrice();
    error StalePrice();
    error InvalidRound();

    function getFreshPriceWad(IPriceFeed feed, uint256 maxStaleness) internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();

        if (answer <= 0) revert InvalidPrice();
        if (updatedAt == 0 || block.timestamp - updatedAt > maxStaleness) revert StalePrice();
        if (answeredInRound < roundId) revert InvalidRound();

        uint8 feedDecimals = feed.decimals();
        // Casting to uint256 is safe because answer <= 0 is rejected above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(answer);

        return price * WAD / (10 ** feedDecimals);
    }
}
