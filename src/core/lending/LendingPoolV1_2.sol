// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {LendingPoolV1_1} from "./LendingPoolV1_1.sol";
import {BorrowIndexMath} from "../../lib/BorrowIndexMath.sol";

/// @notice Local V1.2 implementation candidate with per-second RAY borrow-index accrual.
/// @dev This contract must not be installed on an initialized legacy proxy until the atomic migration mechanism is
///      implemented and verified.
contract LendingPoolV1_2 is LendingPoolV1_1 {
    uint256 private constant V1_2_WAD = 1e18;
    uint256 private constant MAX_DEBT_QUANTUM = 1_000_000;

    error ZeroScaledAmount();
    error UnsupportedDebtAssetDecimals(uint8 actualDecimals);
    error DebtQuantumTooHigh(uint256 quantum, uint256 maximum);

    function version() public pure override returns (string memory) {
        return "1.2";
    }

    function _accruedBorrowIndex(uint256 timeElapsed) internal view override returns (uint256) {
        return BorrowIndexMath.accrueIndex(borrowIndex, currentBorrowRate(), timeElapsed);
    }

    function _scaledToDebt(uint256 scaledAmount, uint256 index) internal pure override returns (uint256) {
        _validateAccountingDomain(index);
        return Math.mulDiv(scaledAmount, index, V1_2_WAD, Math.Rounding.Floor);
    }

    function _debtToUtilization(uint256 debt, uint256 liquidity) internal pure override returns (uint256) {
        return Math.mulDiv(debt, V1_2_WAD, liquidity, Math.Rounding.Floor);
    }

    function _variableBorrowRate(uint256 utilization, uint256 slope) internal pure override returns (uint256) {
        return Math.mulDiv(utilization, slope, V1_2_WAD, Math.Rounding.Floor);
    }

    function _scaledAmountForBorrow(uint256 amount, uint256 index)
        internal
        pure
        override
        returns (uint256 scaledAmount)
    {
        _validateAccountingDomain(index);
        scaledAmount = Math.mulDiv(amount, V1_2_WAD, index, Math.Rounding.Ceil);
        if (scaledAmount == 0) revert ZeroScaledAmount();
    }

    function _scaledAmountForPartialRepayment(uint256 repayment, uint256 index)
        internal
        pure
        override
        returns (uint256 scaledRepayAmount)
    {
        _validateAccountingDomain(index);
        scaledRepayAmount = Math.mulDiv(repayment, V1_2_WAD, index, Math.Rounding.Floor);
        if (scaledRepayAmount == 0) revert ZeroScaledAmount();
    }

    function _reportedDebtAfterPartialRepayment(address user, uint256, uint256)
        internal
        view
        override
        returns (uint256)
    {
        return _scaledToDebt(scaledDebtOf[user], borrowIndex);
    }

    function _validateDebtAsset(address debtAssetAddress) internal view override {
        uint8 actualDecimals = IERC20Metadata(debtAssetAddress).decimals();
        if (actualDecimals != 18) revert UnsupportedDebtAssetDecimals(actualDecimals);
    }

    function _validateAccountingDomain(uint256 index) internal pure override {
        uint256 quantum = Math.ceilDiv(index, V1_2_WAD);
        if (quantum > MAX_DEBT_QUANTUM) revert DebtQuantumTooHigh(quantum, MAX_DEBT_QUANTUM);
    }
}
