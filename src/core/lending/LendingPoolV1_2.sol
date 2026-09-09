// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {LendingPoolV1_1} from "./LendingPoolV1_1.sol";
import {BorrowIndexMath} from "../../lib/BorrowIndexMath.sol";

/// @notice V1.2 implementation with atomic legacy-index settlement and per-second RAY borrow-index accrual.
/// @dev Accounting remains inactive until migrateToV1_2 completes through an active proxy.
contract LendingPoolV1_2 is LendingPoolV1_1 {
    uint256 private constant V1_2_WAD = 1e18;
    uint256 private constant V1_2_SECONDS_PER_YEAR = 365 days;
    uint256 private constant MAX_DEBT_QUANTUM = 1_000_000;
    bytes32 private constant V1_2_INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    error ZeroScaledAmount();
    error V1_2AccountingInactive();
    error BorrowIndexTooLow(uint256 index, uint256 minimum);
    error UnsupportedDebtAssetDecimals(uint8 actualDecimals);
    error DebtQuantumTooHigh(uint256 quantum, uint256 maximum);

    event V1_2Activated(
        uint256 previousBorrowIndex,
        uint256 settledBorrowIndex,
        uint256 elapsedLegacySeconds,
        uint256 activationTimestamp
    );

    // forge-lint: disable-next-line(mixed-case-function)
    function migrateToV1_2() external reinitializer(2) onlyProxy {
        if (msg.sender != upgradeAuthority()) revert UnauthorizedUpgradeAuthority(msg.sender);

        uint256 previousBorrowIndex = borrowIndex;
        uint256 elapsedLegacySeconds = block.timestamp - lastBorrowIndexUpdate;
        _validateMinimumBorrowIndex(previousBorrowIndex);
        uint256 settledBorrowIndex = _settleLegacyBorrowIndex(previousBorrowIndex, elapsedLegacySeconds);

        borrowIndex = settledBorrowIndex;
        lastBorrowIndexUpdate = block.timestamp;

        _validateAccountingDomain(settledBorrowIndex);
        _validateDebtAsset(address(debtAsset));
        _validateInterestRateDomain();

        emit V1_2Activated(previousBorrowIndex, settledBorrowIndex, elapsedLegacySeconds, block.timestamp);
    }

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
        _validateMinimumBorrowIndex(index);

        uint256 quantum = Math.ceilDiv(index, V1_2_WAD);
        if (quantum > MAX_DEBT_QUANTUM) revert DebtQuantumTooHigh(quantum, MAX_DEBT_QUANTUM);
    }

    function _requireAccountingActive() internal view override {
        if (_getInitializedVersion() < 2 || _isInitializing()) revert V1_2AccountingInactive();
    }

    function _settleLegacyBorrowIndex(uint256 storedIndex, uint256 elapsedLegacySeconds)
        internal
        view
        returns (uint256)
    {
        if (elapsedLegacySeconds == 0) return storedIndex;
        if (totalScaledDebt == 0) return storedIndex;

        uint256 utilization;
        if (totalLiquidity != 0) {
            uint256 storedDebt = totalScaledDebt * storedIndex / V1_2_WAD;
            utilization = storedDebt >= totalLiquidity ? V1_2_WAD : storedDebt * V1_2_WAD / totalLiquidity;
        }

        uint256 legacyRate = baseBorrowRate + utilization * borrowRateSlope / V1_2_WAD;
        uint256 interestFactor = legacyRate * elapsedLegacySeconds / V1_2_SECONDS_PER_YEAR;
        uint256 secondOrderTerm = interestFactor * interestFactor / (2 * V1_2_WAD);

        return storedIndex * (V1_2_WAD + interestFactor + secondOrderTerm) / V1_2_WAD;
    }

    function _validateInterestRateDomain() internal view {
        if (baseBorrowRate > V1_2_WAD || borrowRateSlope > V1_2_WAD - baseBorrowRate) {
            revert InvalidInterestRateModel();
        }
    }

    function _validateMinimumBorrowIndex(uint256 index) internal pure {
        if (index < V1_2_WAD) revert BorrowIndexTooLow(index, V1_2_WAD);
    }

    function _initializableStorageSlot() internal pure override returns (bytes32) {
        return V1_2_INITIALIZABLE_STORAGE;
    }
}
