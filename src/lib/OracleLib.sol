// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceFeed} from "../interfaces/IPriceFeed.sol";

library OracleLib {
    error InvalidPrice();
    error StalePrice();
    error InvalidRound();
    error FuturePriceTimestamp(uint256 updatedAt, uint256 currentTimestamp);
    error UnsupportedPriceFeedDecimals(uint8 decimals);
    error PriceNormalizationOverflow();
    error ZeroNormalizedPrice();

    function getFreshPriceWad(IPriceFeed feed, uint256 maxStaleness) internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();

        if (answer <= 0) revert InvalidPrice();
        if (updatedAt == 0) revert StalePrice();
        if (updatedAt > block.timestamp) revert FuturePriceTimestamp(updatedAt, block.timestamp);
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice();
        if (answeredInRound < roundId) revert InvalidRound();

        uint8 feedDecimals = feed.decimals();
        if (feedDecimals > 18) revert UnsupportedPriceFeedDecimals(feedDecimals);

        // Casting to uint256 is safe because answer <= 0 is rejected above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(answer);
        uint256 normalizedPrice;

        if (feedDecimals == 18) {
            normalizedPrice = price;
        } else {
            uint256 scale = 10 ** (18 - feedDecimals);
            if (price > type(uint256).max / scale) revert PriceNormalizationOverflow();
            normalizedPrice = price * scale;
        }

        if (normalizedPrice == 0) revert ZeroNormalizedPrice();
        return normalizedPrice;
    }
}
