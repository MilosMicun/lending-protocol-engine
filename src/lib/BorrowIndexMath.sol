// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @title BorrowIndexMath
/// @notice Fixed-point math for growing a cumulative WAD borrow index at a nominal annual rate.
/// @dev The annual rate and index use WAD units. Per-second compounding and exponentiation use RAY units.
///      Every division rounds down, so the result never exceeds the corresponding quantized real-valued growth.
///      A positive-rate call covers at most 100 periods of exactly 365 days. Zero-time and zero-rate calls are exact
///      identity operations. This library only computes an isolated index; it does not change protocol state.
library BorrowIndexMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD_TO_RAY = 1e9;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant MAX_ACCRUAL_ELAPSED = 100 * SECONDS_PER_YEAR;

    /// @notice The supplied nominal annual rate is outside the supported 0% to 100% WAD domain.
    error BorrowRateTooHigh(uint256 rateWad, uint256 maximumRateWad);

    /// @notice A positive-rate accrual interval exceeds the supported 100-year single-call maximum.
    error AccrualIntervalTooLong(uint256 elapsed, uint256 maximumElapsed);

    /// @notice Grows a WAD index using a WAD nominal APR compounded discretely once per second.
    /// @param indexWad Starting cumulative borrow index in WAD units.
    /// @param rateWad Nominal annual borrow rate in WAD units; must be at most 1e18 (100%).
    /// @param elapsed Number of elapsed seconds. Positive-rate accrual is limited to 100 * 365 days.
    /// @return accruedIndexWad Floor-rounded cumulative borrow index in WAD units.
    function accrueIndex(uint256 indexWad, uint256 rateWad, uint256 elapsed)
        internal
        pure
        returns (uint256 accruedIndexWad)
    {
        if (rateWad > WAD) revert BorrowRateTooHigh(rateWad, WAD);
        if (elapsed == 0 || rateWad == 0) return indexWad;
        if (elapsed > MAX_ACCRUAL_ELAPSED) {
            revert AccrualIntervalTooLong(elapsed, MAX_ACCRUAL_ELAPSED);
        }

        uint256 baseRay = RAY + Math.mulDiv(rateWad, WAD_TO_RAY, SECONDS_PER_YEAR, Math.Rounding.Floor);
        uint256 growthRay = powRayFloor(baseRay, elapsed);

        return Math.mulDiv(indexWad, growthRay, RAY, Math.Rounding.Floor);
    }

    /// @notice Raises a RAY-scaled base to an integer exponent using floor-rounded exponentiation by squaring.
    /// @dev Runs in O(log exponent). The final square is deliberately skipped once the exponent becomes zero.
    /// @param baseRay Nonnegative base in RAY units.
    /// @param exponent Nonnegative integer exponent.
    /// @return resultRay Floor-rounded power in RAY units.
    function powRayFloor(uint256 baseRay, uint256 exponent) internal pure returns (uint256 resultRay) {
        resultRay = RAY;

        while (exponent != 0) {
            if (exponent & 1 != 0) {
                resultRay = Math.mulDiv(resultRay, baseRay, RAY, Math.Rounding.Floor);
            }

            exponent >>= 1;

            if (exponent != 0) {
                baseRay = Math.mulDiv(baseRay, baseRay, RAY, Math.Rounding.Floor);
            }
        }
    }
}
