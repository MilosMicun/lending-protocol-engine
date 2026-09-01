// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";
import {IPriceFeed} from "../../../src/interfaces/IPriceFeed.sol";
import {OracleLib} from "../../../src/lib/OracleLib.sol";

contract OracleLibHarness {
    function getFreshPriceWad(IPriceFeed feed, uint256 maxStaleness) external view returns (uint256) {
        return OracleLib.getFreshPriceWad(feed, maxStaleness);
    }
}

contract OracleLibTest is Test {
    uint256 internal constant MAX_STALENESS = 1 days;
    OracleLibHarness internal harness;

    function setUp() public {
        harness = new OracleLibHarness();
    }

    function test_ValidEightDecimalAnswerNormalizesExactlyToWad() public {
        MockV3Aggregator feed = new MockV3Aggregator(8, 2_000e8, block.timestamp);

        assertEq(harness.getFreshPriceWad(feed, MAX_STALENESS), 2_000e18);
    }

    function test_ValidEighteenDecimalAnswerOfOneReturnsOne() public {
        MockV3Aggregator feed = new MockV3Aggregator(18, 1, block.timestamp);

        assertEq(harness.getFreshPriceWad(feed, MAX_STALENESS), 1);
    }

    function test_NineteenDecimalPositiveAnswerRevertsWithUnsupportedDecimals() public {
        MockV3Aggregator feed = new MockV3Aggregator(19, 1, block.timestamp);

        vm.expectRevert(abi.encodeWithSelector(OracleLib.UnsupportedPriceFeedDecimals.selector, uint8(19)));
        harness.getFreshPriceWad(feed, MAX_STALENESS);
    }

    function test_SeventyEightDecimalFeedRevertsWithUnsupportedDecimals() public {
        MockV3Aggregator feed = new MockV3Aggregator(78, 1, block.timestamp);

        vm.expectRevert(abi.encodeWithSelector(OracleLib.UnsupportedPriceFeedDecimals.selector, uint8(78)));
        harness.getFreshPriceWad(feed, MAX_STALENESS);
    }

    function test_FutureUpdatedAtRevertsWithFutureTimestamp() public {
        uint256 futureUpdatedAt = block.timestamp + 1;
        MockV3Aggregator feed = new MockV3Aggregator(8, 1e8, futureUpdatedAt);

        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.FuturePriceTimestamp.selector, futureUpdatedAt, block.timestamp)
        );
        harness.getFreshPriceWad(feed, MAX_STALENESS);
    }

    function test_SupportedDecimalScalingOverflowRevertsWithNormalizationOverflow() public {
        MockV3Aggregator feed = new MockV3Aggregator(0, type(int256).max, block.timestamp);

        vm.expectRevert(OracleLib.PriceNormalizationOverflow.selector);
        harness.getFreshPriceWad(feed, MAX_STALENESS);
    }
}
