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
    LendingPool public pool;
    MockERC20 public asset;
    MockV3Aggregator public priceFeed;

    address[] public users;

    uint256 public successfulBorrows;

    constructor(LendingPool poolProxy_, MockERC20 asset_, MockV3Aggregator priceFeed_, address[] memory users_) {
        pool = poolProxy_;
        asset = asset_;
        priceFeed = priceFeed_;

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

        uint256 maxBorrow = pool.maxBorrowOf(user);
        uint256 debt = pool.debtBalanceOf(user);
        uint256 available = pool.availableLiquidity();

        if (maxBorrow <= debt || available == 0) return;

        uint256 remainingBorrowCapacity = maxBorrow - debt;
        uint256 upperBound = remainingBorrowCapacity < available ? remainingBorrowCapacity : available;

        amount = bound(amount, 1, upperBound);

        vm.prank(user);
        try pool.borrow(amount) {
            successfulBorrows++;
        } catch {}
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
        address borrower = _getUser(borrowerSeed);

        uint256 debt = pool.debtBalanceOf(borrower);
        if (debt == 0) return;

        if (!pool.isLiquidatable(borrower)) return;

        repayAmount = bound(repayAmount, 1, debt);

        asset.mint(address(this), repayAmount);
        asset.approve(address(pool), repayAmount);
        // NOTE:
        // liquidate may legitimately revert because borrower state can change
        // between handler actions during invariant exploration.
        // Unexpected liquidation edge cases are covered by dedicated fuzz/unit tests.
        try pool.liquidate(borrower, repayAmount) {} catch {}
    }

    function warpTime(uint256 timeElapsed) external {
        timeElapsed = bound(timeElapsed, 1, 30 days);

        vm.warp(block.timestamp + timeElapsed);
        priceFeed.setUpdatedAt(block.timestamp);
    }

    function _getUser(uint256 seed) internal view returns (address) {
        return users[seed % users.length];
    }
}
