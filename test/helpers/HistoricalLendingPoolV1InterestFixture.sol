// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test-only model of historical V1 liquidity-mutation interest behavior.
/// @dev This standalone fixture is not deployed V1 bytecode and does not reproduce the full protocol. It models only
///      the old second-order index, stored-debt utilization, and absence of a checkpoint on liquidity mutation.
contract HistoricalLendingPoolV1InterestFixture {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    uint256 public borrowIndex = WAD;
    uint256 public lastBorrowIndexUpdate;
    uint256 public totalLiquidity;
    uint256 public totalScaledDebt;
    uint256 public baseBorrowRate;
    uint256 public borrowRateSlope;

    constructor(uint256 baseBorrowRate_, uint256 borrowRateSlope_) {
        baseBorrowRate = baseBorrowRate_;
        borrowRateSlope = borrowRateSlope_;
        lastBorrowIndexUpdate = block.timestamp;
    }

    function openPosition(uint256 liquidity, uint256 scaledDebt) external {
        totalLiquidity = liquidity;
        totalScaledDebt = scaledDebt;
        lastBorrowIndexUpdate = block.timestamp;
    }

    function depositLiquidity(uint256 amount) external {
        totalLiquidity += amount;
    }

    function currentBorrowIndex() external view returns (uint256) {
        uint256 elapsed = block.timestamp - lastBorrowIndexUpdate;
        if (elapsed == 0 || totalScaledDebt == 0) return borrowIndex;

        uint256 rate = currentBorrowRate();
        uint256 interestFactor = rate * elapsed / SECONDS_PER_YEAR;
        uint256 secondOrderTerm = interestFactor * interestFactor / (2 * WAD);
        return borrowIndex * (WAD + interestFactor + secondOrderTerm) / WAD;
    }

    function currentBorrowRate() public view returns (uint256) {
        uint256 storedDebt = totalScaledDebt * borrowIndex / WAD;
        uint256 utilization;
        if (totalLiquidity != 0) utilization = storedDebt >= totalLiquidity ? WAD : storedDebt * WAD / totalLiquidity;
        return baseBorrowRate + utilization * borrowRateSlope / WAD;
    }
}
