// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {BorrowIndexMath} from "../../../src/lib/BorrowIndexMath.sol";

contract BorrowIndexMathHarness {
    uint256 public marker;

    function accrueIndex(uint256 indexWad, uint256 rateWad, uint256 elapsed) external pure returns (uint256) {
        return BorrowIndexMath.accrueIndex(indexWad, rateWad, elapsed);
    }

    function powRayFloor(uint256 baseRay, uint256 exponent) external pure returns (uint256) {
        return BorrowIndexMath.powRayFloor(baseRay, exponent);
    }

    function accrueAndMark(uint256 indexWad, uint256 rateWad, uint256 elapsed) external returns (uint256 result) {
        marker = 1;
        result = BorrowIndexMath.accrueIndex(indexWad, rateWad, elapsed);
        marker = 2;
    }

    function operationCounts(uint256 exponent)
        external
        pure
        returns (uint256 iterations, uint256 accumulatorMultiplications, uint256 squarings)
    {
        while (exponent != 0) {
            ++iterations;
            if (exponent & 1 != 0) ++accumulatorMultiplications;
            exponent >>= 1;
            if (exponent != 0) ++squarings;
        }
    }
}

contract BorrowIndexMathTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant MAX_ELAPSED = 100 * YEAR;
    uint256 internal constant MAX_UINT256 = type(uint256).max;

    BorrowIndexMathHarness internal harness;

    function setUp() public {
        harness = new BorrowIndexMathHarness();
    }

    function test_ZeroElapsedReturnsOriginalUnitIndex() public view {
        assertEq(harness.accrueIndex(WAD, WAD, 0), WAD);
    }

    function test_ZeroElapsedReturnsOriginalElevatedIndex() public view {
        assertEq(harness.accrueIndex(1e24, WAD, 0), 1e24);
    }

    function test_ZeroRateReturnsOriginalIndexBeyondMaximumElapsed() public view {
        assertEq(harness.accrueIndex(1e24, 0, MAX_ELAPSED + 1), 1e24);
        assertEq(harness.accrueIndex(MAX_UINT256, 0, MAX_UINT256), MAX_UINT256);
    }

    function test_OneSecondTinyPositiveRateCanLeaveWadIndexUnchanged() public view {
        assertEq(harness.accrueIndex(WAD, 1, 1), WAD);
        assertEq(harness.accrueIndex(WAD, 31, 1), WAD);
        assertEq(harness.accrueIndex(WAD, 32, 1), WAD);
    }

    function test_PowZeroExponentReturnsRay() public view {
        assertEq(harness.powRayFloor(MAX_UINT256, 0), RAY);
    }

    function test_RateAboveWadRevertsWithExactArguments() public {
        vm.expectRevert(abi.encodeWithSelector(BorrowIndexMath.BorrowRateTooHigh.selector, WAD + 1, WAD));
        harness.accrueIndex(WAD, WAD + 1, 0);
    }

    function test_PositiveRateAcceptsMaximumElapsed() public view {
        assertEq(
            harness.accrueIndex(WAD, WAD, MAX_ELAPSED), 26881128798378344518912877811038280859564355321045156268014032
        );
    }

    function test_PositiveRateAboveMaximumElapsedRevertsWithExactArguments() public {
        vm.expectRevert(
            abi.encodeWithSelector(BorrowIndexMath.AccrualIntervalTooLong.selector, MAX_ELAPSED + 1, MAX_ELAPSED)
        );
        harness.accrueIndex(WAD, 1, MAX_ELAPSED + 1);
    }

    function test_AllFiftySixIndependentReferenceVectorsMatchExactly() public view {
        uint256[7] memory rates = [uint256(0), WAD / 100, WAD / 20, WAD / 10, WAD / 5, WAD / 2, WAD];
        uint256[8] memory elapsed = [uint256(1), 1 days, 30 days, YEAR, 5 * YEAR, 20 * YEAR, 50 * YEAR, MAX_ELAPSED];
        uint256[56] memory expected = [
            uint256(1000000000000000000),
            uint256(1000000000000000000),
            uint256(1000000000000000000),
            uint256(1000000000000000000),
            uint256(1000000000000000000),
            uint256(1000000000000000000),
            uint256(1000000000000000000),
            uint256(1000000000000000000),
            uint256(1000000000317097919),
            uint256(1000027397635577991),
            uint256(1000822255675090451),
            uint256(1010050167082566633),
            uint256(1051271096367690142),
            uint256(1221402758121439406),
            uint256(1648721270569426623),
            uint256(2718281828028064473),
            uint256(1000000001585489599),
            uint256(1000136995684313079),
            uint256(1004118044978380148),
            uint256(1051271096334354554),
            uint256(1284025416433265366),
            uint256(2718281826304141454),
            uint256(12182493936559451644),
            uint256(148413158514307804622),
            uint256(1000000003170979198),
            uint256(1000274010136226429),
            uint256(1008253048244634773),
            uint256(1105170917900423925),
            uint256(1648721269393112936),
            uint256(7389056075500107124),
            uint256(148413157926039009650),
            uint256(22026465445579395712234),
            uint256(1000000006341958396),
            uint256(1000548095353138376),
            uint256(1016574209268103001),
            uint256(1221402757385561289),
            uint256(2718281819839430151),
            uint256(54598149340625854252),
            uint256(22026465096352082007082),
            uint256(485165164640816533295966865),
            uint256(1000000015854895991),
            uint256(1001370801693739430),
            uint256(1041952013622638824),
            uint256(1648721264165052162),
            uint256(12182493719263260045),
            uint256(22026464048670182948314),
            uint256(72004885067010063621309131407),
            uint256(5184703473513328854280443739097856579777),
            uint256(1000000031709791983),
            uint256(1002743482462983798),
            uint256(1085663997984884493),
            uint256(2718281785360970821),
            uint256(148413147337201311476),
            uint256(485165041564943679843586237),
            uint256(5184701418440443279806135926559824046009),
            uint256(26881128798378344518912877811038280859564355321045156268014032)
        ];

        for (uint256 rateIndex; rateIndex < rates.length; ++rateIndex) {
            for (uint256 timeIndex; timeIndex < elapsed.length; ++timeIndex) {
                uint256 vectorIndex = rateIndex * elapsed.length + timeIndex;
                assertEq(harness.accrueIndex(WAD, rates[rateIndex], elapsed[timeIndex]), expected[vectorIndex]);
            }
        }
    }

    function test_ElevatedIndexReferenceVectorsMatchExactly() public view {
        assertEq(harness.accrueIndex(2 * WAD, WAD / 20, YEAR), 2102542192668709109);
        assertEq(harness.accrueIndex(2 * WAD, WAD / 5, 20 * YEAR), 109196298681251708505);
        assertEq(harness.accrueIndex(2 * WAD, WAD, 50 * YEAR), 10369402836880886559612271853119648092018);

        assertEq(harness.accrueIndex(1e24, WAD / 20, YEAR), 1051271096334354554994858);
        assertEq(harness.accrueIndex(1e24, WAD / 5, 20 * YEAR), 54598149340625854252601888);
        assertEq(harness.accrueIndex(1e24, WAD, 50 * YEAR), 5184701418440443279806135926559824046009016852);
    }

    function test_TimeAndRateBoundaryCasesAreMonotonic() public view {
        uint256[9] memory elapsed =
            [uint256(1), 1 days, 30 days, YEAR, 5 * YEAR, 20 * YEAR, 50 * YEAR, MAX_ELAPSED - 1, MAX_ELAPSED];
        uint256[6] memory rates = [uint256(1), uint256(31), uint256(32), WAD - 1, WAD / 2, WAD];

        for (uint256 rateIndex; rateIndex < rates.length; ++rateIndex) {
            uint256 previous = WAD;
            for (uint256 timeIndex; timeIndex < elapsed.length; ++timeIndex) {
                uint256 current = harness.accrueIndex(WAD, rates[rateIndex], elapsed[timeIndex]);
                assertGe(current, previous);
                previous = current;
            }
        }
    }

    function test_PartitionSchedulesStayWithinCombinedOutwardRoundedBound() public view {
        uint256 totalElapsed = 5 * YEAR;
        uint256 rateWad = WAD / 5;
        uint256 single = harness.accrueIndex(WAD, rateWad, totalElapsed);
        uint256 idealCeiling = 2718281819839430153;
        _assertIdealBound(single, idealCeiling, totalElapsed, 1);

        uint256[] memory twoParts = new uint256[](2);
        twoParts[0] = totalElapsed / 3;
        twoParts[1] = totalElapsed - twoParts[0];
        uint256 twoPartIndex = _accruePartitions(WAD, rateWad, twoParts);
        _assertIdealBound(twoPartIndex, idealCeiling, totalElapsed, 2);
        _assertPartitionBound(single, twoPartIndex, totalElapsed, 2);

        _assertUniformPartitionBound(single, idealCeiling, WAD, rateWad, totalElapsed, YEAR);
        _assertUniformPartitionBound(single, idealCeiling, WAD, rateWad, totalElapsed, YEAR / 12);
        _assertUniformPartitionBound(single, idealCeiling, WAD, rateWad, totalElapsed, 1 days);
    }

    function test_ThirtyTwoDeterministicRandomPartitionsStayWithinBound() public view {
        uint256 totalElapsed = 20 * YEAR;
        uint256 rateWad = WAD / 2;
        uint256 single = harness.accrueIndex(2 * WAD, rateWad, totalElapsed);
        uint256 idealCeiling = 44052928097340365916933;
        _assertIdealBound(single, idealCeiling, totalElapsed, 1);

        for (uint256 seed; seed < 32; ++seed) {
            uint256[] memory partitions = _randomPositivePartitions(totalElapsed, 17, seed);
            uint256 partitioned = _accruePartitions(2 * WAD, rateWad, partitions);
            _assertIdealBound(partitioned, idealCeiling, totalElapsed, partitions.length);
            _assertPartitionBound(single, partitioned, totalElapsed, partitions.length);
        }
    }

    function test_ZeroRateIsPartitionInvariant() public view {
        uint256[] memory partitions = _randomPositivePartitions(MAX_ELAPSED, 32, 6006000);
        assertEq(_accruePartitions(1e24, 0, partitions), 1e24);
    }

    function test_FullWidthFinalProductSucceedsWhenQuotientFits() public view {
        uint256 indexWad = MAX_UINT256 / 2;
        uint256 growthRay = 1000000031709791983764586504;
        assertGt(indexWad, MAX_UINT256 / growthRay);
        assertEq(
            harness.accrueIndex(indexWad, WAD, 1),
            57896046454529629252186865893958016857331964541966480608562759844769525231061
        );
    }

    function test_LargestRepresentableFinalQuotientSucceeds() public view {
        uint256 indexWad = 115792089237316195423570981419133141496467926534940140046330197617407407056791;
        assertEq(harness.accrueIndex(indexWad, 1, 1), MAX_UINT256);
    }

    function test_FinalQuotientAboveUint256RevertsWithArithmeticPanic() public {
        uint256 indexWad = 115792089237316195423570981419133141496467926534940140046330197617407407056792;
        vm.expectRevert(stdError.arithmeticError);
        harness.accrueIndex(indexWad, 1, 1);
    }

    function test_FinalSquareIsSkippedAfterExponentBecomesZero() public view {
        assertEq(harness.powRayFloor(MAX_UINT256, 1), MAX_UINT256);
    }

    function test_BaseSquaringOverflowRevertsWithArithmeticPanic() public {
        vm.expectRevert(stdError.arithmeticError);
        harness.powRayFloor(MAX_UINT256, 2);
    }

    function test_AccumulatedGrowthOverflowRevertsWithArithmeticPanic() public {
        vm.expectRevert(stdError.arithmeticError);
        harness.powRayFloor(2 * RAY, 256);
    }

    function test_RevertingPureMathRollsBackCallingTransactionAtomically() public {
        assertEq(harness.accrueAndMark(WAD, WAD / 20, YEAR), 1051271096334354554);
        assertEq(harness.marker(), 2);

        vm.expectRevert(stdError.arithmeticError);
        harness.accrueAndMark(MAX_UINT256, WAD, 1);
        assertEq(harness.marker(), 2);
    }

    function test_OperationCountMaximaAreLogarithmicAcrossSupportedDomain() public view {
        (uint256 maxTimeIterations, uint256 maxTimeAccumulators, uint256 maxTimeSquarings) =
            harness.operationCounts(MAX_ELAPSED);
        assertEq(maxTimeIterations, 32);
        assertEq(maxTimeAccumulators, 15);
        assertEq(maxTimeSquarings, 31);

        (uint256 popcountIterations, uint256 maxAccumulators, uint256 popcountSquarings) =
            harness.operationCounts((uint256(1) << 31) - 1);
        assertEq(popcountIterations, 31);
        assertEq(maxAccumulators, 31);
        assertEq(popcountSquarings, 30);

        (uint256 combinedIterations, uint256 combinedAccumulators, uint256 combinedSquarings) =
            harness.operationCounts((uint256(1) << 31) + (uint256(1) << 29) - 1);
        assertEq(combinedIterations, 32);
        assertEq(combinedAccumulators, 30);
        assertEq(combinedSquarings, 31);
        assertEq(combinedAccumulators + combinedSquarings, 61);
    }

    function testFuzz_AccruedIndexNeverFallsBelowStartingIndex(uint256 indexSeed, uint256 rateSeed, uint256 elapsedSeed)
        public
        view
    {
        uint256 indexWad = bound(indexSeed, WAD, 1e24);
        uint256 rateWad = bound(rateSeed, 0, WAD);
        uint256 elapsed = bound(elapsedSeed, 0, MAX_ELAPSED);

        assertGe(harness.accrueIndex(indexWad, rateWad, elapsed), indexWad);
    }

    function testFuzz_LaterElapsedCannotProduceLowerIndex(
        uint256 indexSeed,
        uint256 rateSeed,
        uint256 firstSeed,
        uint256 secondSeed
    ) public view {
        uint256 indexWad = bound(indexSeed, WAD, 1e24);
        uint256 rateWad = bound(rateSeed, 0, WAD);
        uint256 firstElapsed = bound(firstSeed, 0, MAX_ELAPSED);
        uint256 secondElapsed = bound(secondSeed, 0, MAX_ELAPSED);
        if (firstElapsed > secondElapsed) (firstElapsed, secondElapsed) = (secondElapsed, firstElapsed);

        assertLe(
            harness.accrueIndex(indexWad, rateWad, firstElapsed), harness.accrueIndex(indexWad, rateWad, secondElapsed)
        );
    }

    function testFuzz_ZeroRateAndZeroTimeAreExactIdentity(uint256 indexWad, uint256 rateSeed, uint256 elapsedSeed)
        public
        view
    {
        uint256 rateWad = bound(rateSeed, 0, WAD);
        uint256 elapsed = bound(elapsedSeed, 0, MAX_UINT256);

        assertEq(harness.accrueIndex(indexWad, 0, elapsed), indexWad);
        assertEq(harness.accrueIndex(indexWad, rateWad, 0), indexWad);
    }

    function testFuzz_TwoPartAccrualStaysWithinRigorousCombinedBound(
        uint256 indexSeed,
        uint256 rateSeed,
        uint256 totalSeed,
        uint256 splitSeed
    ) public view {
        uint256 indexWad = bound(indexSeed, WAD, 1e24);
        uint256 rateWad = bound(rateSeed, 0, WAD);
        uint256 totalElapsed = bound(totalSeed, 2, MAX_ELAPSED);
        uint256 firstElapsed = bound(splitSeed, 1, totalElapsed - 1);
        uint256 single = harness.accrueIndex(indexWad, rateWad, totalElapsed);
        uint256 partitioned = harness.accrueIndex(indexWad, rateWad, firstElapsed);
        partitioned = harness.accrueIndex(partitioned, rateWad, totalElapsed - firstElapsed);

        _assertPartitionBound(single, partitioned, totalElapsed, 2);
    }

    function testFuzz_BoundedMultiPartAccrualStaysWithinRigorousCombinedBound(
        uint256 indexSeed,
        uint256 rateSeed,
        uint256 totalSeed,
        uint256 countSeed,
        uint256 partitionSeed
    ) public view {
        uint256 indexWad = bound(indexSeed, WAD, 1e24);
        uint256 rateWad = bound(rateSeed, 0, WAD);
        uint256 totalElapsed = bound(totalSeed, 2, MAX_ELAPSED);
        uint256 count = bound(countSeed, 2, Math.min(16, totalElapsed));
        uint256[] memory partitions = _randomPositivePartitions(totalElapsed, count, partitionSeed);
        uint256 single = harness.accrueIndex(indexWad, rateWad, totalElapsed);
        uint256 partitioned = _accruePartitions(indexWad, rateWad, partitions);

        _assertPartitionBound(single, partitioned, totalElapsed, count);
    }

    function testFuzz_OperationCountsRemainWithinProvenLogarithmicMaxima(uint256 elapsedSeed) public view {
        uint256 elapsed = bound(elapsedSeed, 0, MAX_ELAPSED);
        (uint256 iterations, uint256 accumulators, uint256 squarings) = harness.operationCounts(elapsed);

        assertLe(iterations, 32);
        assertLe(accumulators, 31);
        assertLe(squarings, 31);
        assertLe(accumulators + squarings, 61);
    }

    function _assertUniformPartitionBound(
        uint256 single,
        uint256 idealCeiling,
        uint256 indexWad,
        uint256 rateWad,
        uint256 totalElapsed,
        uint256 step
    ) internal view {
        uint256 count = totalElapsed / step;
        uint256 remainder = totalElapsed % step;
        if (remainder != 0) ++count;
        uint256[] memory partitions = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            partitions[i] = step;
        }
        if (remainder != 0) partitions[count - 1] = remainder;

        uint256 partitioned = _accruePartitions(indexWad, rateWad, partitions);
        _assertIdealBound(partitioned, idealCeiling, totalElapsed, count);
        _assertPartitionBound(single, partitioned, totalElapsed, count);
    }

    function _randomPositivePartitions(uint256 totalElapsed, uint256 count, uint256 seed)
        internal
        pure
        returns (uint256[] memory partitions)
    {
        partitions = new uint256[](count);
        uint256 remaining = totalElapsed;

        for (uint256 i; i + 1 < count; ++i) {
            uint256 laterMinimum = count - i - 1;
            uint256 available = remaining - laterMinimum;
            uint256 entropy = uint256(keccak256(abi.encode(seed, i)));
            uint256 part = 1 + entropy % available;
            partitions[i] = part;
            remaining -= part;
        }
        partitions[count - 1] = remaining;
    }

    function _accruePartitions(uint256 indexWad, uint256 rateWad, uint256[] memory partitions)
        internal
        view
        returns (uint256 accruedIndexWad)
    {
        accruedIndexWad = indexWad;
        for (uint256 i; i < partitions.length; ++i) {
            accruedIndexWad = harness.accrueIndex(accruedIndexWad, rateWad, partitions[i]);
        }
    }

    function _assertPartitionBound(uint256 single, uint256 partitioned, uint256 totalElapsed, uint256 partitionCount)
        internal
        pure
    {
        uint256 combinedBoundRay = 4 * totalElapsed + (partitionCount + 1) * 1e9;
        uint256 largestPathErrorRay = 2 * totalElapsed + Math.max(partitionCount, 1) * 1e9;
        uint256 larger = Math.max(single, partitioned);
        uint256 tolerance = Math.mulDiv(larger, combinedBoundRay, RAY - largestPathErrorRay, Math.Rounding.Ceil);
        uint256 difference = single > partitioned ? single - partitioned : partitioned - single;

        assertLe(difference, tolerance);
    }

    function _assertIdealBound(uint256 actual, uint256 idealCeiling, uint256 totalElapsed, uint256 checkpointCount)
        internal
        pure
    {
        uint256 implementationBoundRay = 2 * totalElapsed + checkpointCount * 1e9;
        uint256 tolerance = Math.mulDiv(idealCeiling, implementationBoundRay, RAY, Math.Rounding.Ceil) + 1;

        assertLe(actual, idealCeiling);
        assertLe(idealCeiling - actual, tolerance);
    }
}
