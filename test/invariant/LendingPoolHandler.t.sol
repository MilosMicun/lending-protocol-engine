// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

import {LendingPool} from "../../src/core/lending/LendingPool.sol";

// NOTE: This invariant handler intentionally covers the core lending lifecycle:
// deposit liquidity, deposit collateral, borrow, repay, liquidate, and time progression.
// Withdraw flows and multi-LP accounting are covered by unit/integration tests
// and are outside this handler scope.
contract LendingPoolHandler is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MINIMUM_COLLATERAL = 100 ether;

    LendingPool public pool;
    MockERC20 public asset;
    MockV3Aggregator public priceFeed;

    address[] public users;

    uint256 public attemptedBorrowCalls;
    uint256 public successfulBorrowCalls;
    uint256 public expectedRejectedBorrowCalls;
    uint256 public attemptedLiquidationCalls;
    uint256 public successfulLiquidationCalls;
    uint256 public expectedRejectedLiquidationCalls;

    int256 internal immutable REFERENCE_PRICE;
    uint256 internal immutable REFERENCE_PRICE_WAD;
    address internal lastBorrower;

    constructor(LendingPool poolProxy_, MockERC20 asset_, MockV3Aggregator priceFeed_, address[] memory users_) {
        pool = poolProxy_;
        asset = asset_;
        priceFeed = priceFeed_;

        (, int256 answer,,,) = priceFeed_.latestRoundData();
        REFERENCE_PRICE = answer;
        // The invariant fixture constructs the mock with a positive, eight-decimal answer.
        // forge-lint: disable-next-line(unsafe-typecast)
        REFERENCE_PRICE_WAD = uint256(answer) * 10 ** (18 - priceFeed_.decimals());

        for (uint256 i = 0; i < users_.length; i++) {
            users.push(users_[i]);
        }
    }

    function userCount() external view returns (uint256) {
        return users.length;
    }

    function depositLiquidity(uint256 amount) external {
        amount = bound(amount, 1, 1_000 ether);

        asset.mint(address(this), amount);
        asset.approve(address(pool), amount);

        pool.depositLiquidity(amount);
    }

    function depositCollateral(uint256 userSeed, uint256 amount) external {
        address user = _getUser(userSeed);

        amount = bound(amount, 1, 1_000 ether);

        asset.mint(user, amount);

        vm.startPrank(user);
        asset.approve(address(pool), amount);
        pool.depositCollateral(amount);
        vm.stopPrank();
    }

    function borrow(uint256 userSeed, uint256 amount) external {
        address user = _getUser(userSeed);

        _setReferencePrice();
        _ensureBorrowCapacity(user);

        uint256 maxBorrow = pool.maxBorrowOf(user);
        uint256 debt = pool.debtBalanceOf(user);
        uint256 remainingBorrowCapacity = maxBorrow - debt;
        _ensureAvailableLiquidity(remainingBorrowCapacity);

        uint256 lowerBound = (remainingBorrowCapacity + 1) / 2;
        amount = bound(amount, lowerBound, remainingBorrowCapacity);

        attemptedBorrowCalls++;
        vm.prank(user);
        // The immediately preceding bounds make every protocol rejection unexpected.
        pool.borrow(amount);
        successfulBorrowCalls++;
        lastBorrower = user;
    }

    function repay(uint256 userSeed, uint256 amount) external {
        address user = _getUser(userSeed);

        uint256 debt = pool.debtBalanceOf(user);
        if (debt == 0) return;

        amount = bound(amount, 1, debt);

        asset.mint(user, amount);

        vm.startPrank(user);
        asset.approve(address(pool), amount);
        pool.repay(amount);
        vm.stopPrank();
    }

    function liquidate(uint256 borrowerSeed, uint256 repayAmount) external {
        // The smallest valid oracle answer makes a bounded, debt-backed handler position unhealthy.
        priceFeed.setAnswer(1);

        address borrower = _getLiquidatableBorrower(borrowerSeed);
        if (borrower == address(0)) return;

        uint256 debt = pool.debtBalanceOf(borrower);

        repayAmount = bound(repayAmount, 1, debt);

        asset.mint(address(this), repayAmount);
        asset.approve(address(pool), repayAmount);

        attemptedLiquidationCalls++;
        // Debt, unhealthy health factor, balance, and allowance are fixed immediately before this call.
        try pool.liquidate(borrower, repayAmount) {
            successfulLiquidationCalls++;
        } catch (bytes memory reason) {
            bytes4 selector = _selectorOrRevert(reason);

            // BadDebt() has no arguments, so its canonical payload is exactly the four-byte selector.
            // Collateral worth one wei cannot cover a positive repayment after the liquidation bonus.
            if (selector == LendingPool.BadDebt.selector && reason.length == 4) {
                expectedRejectedLiquidationCalls++;
                return;
            }

            _revert(reason);
        }
    }

    function warpTime(uint256 timeElapsed) external {
        timeElapsed = bound(timeElapsed, 1, 30 days);

        vm.warp(block.timestamp + timeElapsed);
        priceFeed.setUpdatedAt(block.timestamp);
    }

    function _getUser(uint256 seed) internal view returns (address) {
        return users[seed % users.length];
    }

    function _getLiquidatableBorrower(uint256 seed) internal view returns (address) {
        if (lastBorrower != address(0) && _hasLiquidatableDebtBackedCollateral(lastBorrower)) {
            return lastBorrower;
        }

        uint256 start = seed % users.length;
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[(start + i) % users.length];
            if (_hasLiquidatableDebtBackedCollateral(user)) return user;
        }

        return address(0);
    }

    function _hasLiquidatableDebtBackedCollateral(address user) internal view returns (bool) {
        return pool.getCollateralAssets(user) >= 1e8 && pool.isLiquidatable(user);
    }

    function _ensureBorrowCapacity(address user) internal {
        uint256 collateralAssets = pool.getCollateralAssets(user);
        if (collateralAssets < MINIMUM_COLLATERAL) {
            _depositCollateral(user, MINIMUM_COLLATERAL - collateralAssets);
        }

        uint256 debt = pool.debtBalanceOf(user);
        uint256 maxBorrow = pool.maxBorrowOf(user);
        if (maxBorrow > debt) return;

        uint256 targetCollateralValue = _ceilDiv((debt + 1) * BPS, pool.ltvBps());
        uint256 currentCollateralValue = pool.getCollateralValue(user);
        uint256 additionalCollateralValue = targetCollateralValue - currentCollateralValue;
        uint256 additionalCollateralAssets = _ceilDiv(additionalCollateralValue * WAD, REFERENCE_PRICE_WAD);

        _depositCollateral(user, additionalCollateralAssets);
    }

    function _ensureAvailableLiquidity(uint256 required) internal {
        uint256 totalDebt = pool.totalDebt();
        uint256 totalLiquidity = pool.totalLiquidity();
        uint256 balance = asset.balanceOf(address(pool));

        uint256 accountingShortfall;
        if (totalLiquidity >= totalDebt) {
            uint256 available = totalLiquidity - totalDebt;
            accountingShortfall = available < required ? required - available : 0;
        } else {
            accountingShortfall = totalDebt - totalLiquidity + required;
        }

        uint256 balanceShortfall = balance < required ? required - balance : 0;
        uint256 amount = accountingShortfall > balanceShortfall ? accountingShortfall : balanceShortfall;
        if (amount == 0) return;

        asset.mint(address(this), amount);
        asset.approve(address(pool), amount);
        pool.depositLiquidity(amount);
    }

    function _depositCollateral(address user, uint256 amount) internal {
        asset.mint(user, amount);

        vm.startPrank(user);
        asset.approve(address(pool), amount);
        pool.depositCollateral(amount);
        vm.stopPrank();
    }

    function _setReferencePrice() internal {
        priceFeed.setAnswer(REFERENCE_PRICE);
    }

    function _ceilDiv(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (numerator == 0) return 0;
        return (numerator - 1) / denominator + 1;
    }

    function _selectorOrRevert(bytes memory reason) internal pure returns (bytes4 selector) {
        if (reason.length < 4) _revert(reason);

        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }
    }

    function _revert(bytes memory reason) internal pure {
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }
}
