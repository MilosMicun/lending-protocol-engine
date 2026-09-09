// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LendingPoolProxyFixture} from "../helpers/LendingPoolProxyFixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

import {LendingPool} from "../../src/core/lending/LendingPool.sol";
import {LendingPoolV1_2} from "../../src/core/lending/LendingPoolV1_2.sol";
import {CollateralVault} from "../../src/core/vault/CollateralVault.sol";

contract LendingPoolV1_2FuzzTest is Test, LendingPoolProxyFixture {
    using stdStorage for StdStorage;

    uint256 internal constant WAD = 1e18;

    MockERC20 internal collateralToken;
    MockERC20 internal debtToken;
    CollateralVault internal vault;
    MockV3Aggregator internal priceFeed;
    LendingPoolV1_2 internal pool;

    address internal provider = makeAddr("provider");
    address internal userOne = makeAddr("userOne");
    address internal userTwo = makeAddr("userTwo");
    address internal userThree = makeAddr("userThree");

    function setUp() public {
        collateralToken = new MockERC20("Collateral", "COL");
        debtToken = new MockERC20("Debt", "DEBT");
        vault = new CollateralVault("Vault Share", "VSH", collateralToken);
        priceFeed = new MockV3Aggregator(8, 1e8, block.timestamp);

        LendingPoolV1_2 implementation = new LendingPoolV1_2();
        pool = LendingPoolV1_2(
            address(
                _deployLendingPoolProxy(
                    implementation,
                    LendingPoolProxyConfig({
                        priceFeed: address(priceFeed),
                        vault: address(vault),
                        debtAsset: address(debtToken),
                        maxPriceStaleness: 101 * 365 days,
                        ltvBps: 7_000,
                        liquidationThresholdBps: 8_000,
                        liquidationBonusBps: 500,
                        baseBorrowRate: 0.1e18,
                        borrowRateSlope: 0.1e18,
                        initialUpgradeAuthority: address(this)
                    })
                )
            )
        );
        pool.migrateToV1_2();

        address[4] memory actors = [provider, userOne, userTwo, userThree];
        for (uint256 i; i < actors.length; ++i) {
            collateralToken.mint(actors[i], 1e30);
            debtToken.mint(actors[i], 1e30);
            vm.startPrank(actors[i]);
            collateralToken.approve(address(pool), type(uint256).max);
            debtToken.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }

        vm.prank(provider);
        pool.depositLiquidity(1e29);

        _depositCollateral(userOne, 1e28);
        _depositCollateral(userTwo, 1e28);
        _depositCollateral(userThree, 1e28);
    }

    function testFuzz_ElevatedIndexBorrowNormalization(uint256 index, uint256 amount) public {
        index = bound(index, WAD, 1e24);
        amount = bound(amount, 1, 1e24);
        _setBorrowIndex(index);

        uint256 balanceBefore = debtToken.balanceOf(userOne);
        vm.prank(userOne);
        pool.borrow(amount);

        uint256 scaled = Math.mulDiv(amount, WAD, index, Math.Rounding.Ceil);
        uint256 displayed = Math.mulDiv(scaled, index, WAD, Math.Rounding.Floor);

        assertEq(pool.scaledDebtOf(userOne), scaled);
        assertEq(pool.debtBalanceOf(userOne), displayed);
        assertGt(scaled, 0);
        assertGe(displayed, amount);
        assertLe(displayed, amount + Math.ceilDiv(index, WAD) - 1);
        assertEq(debtToken.balanceOf(userOne), balanceBefore + amount);
    }

    function testFuzz_ActualLtvAdmissionUsesNormalizedDebt(uint256 index, uint256 collateralAmount) public {
        index = bound(index, WAD, 1e24);
        collateralAmount = bound(collateralAmount, 2, 1e24);

        address actor = makeAddr("ltvActor");
        collateralToken.mint(actor, collateralAmount);
        vm.startPrank(actor);
        collateralToken.approve(address(pool), collateralAmount);
        pool.depositCollateral(collateralAmount);
        vm.stopPrank();

        _setBorrowIndex(index);
        uint256 amount = pool.maxBorrowOf(actor);
        if (amount == 0) return;

        uint256 scaled = Math.mulDiv(amount, WAD, index, Math.Rounding.Ceil);
        uint256 normalized = Math.mulDiv(scaled, index, WAD, Math.Rounding.Floor);

        vm.prank(actor);
        if (normalized > amount) {
            vm.expectRevert(LendingPool.BorrowExceedsLimit.selector);
            pool.borrow(amount);
            assertEq(pool.scaledDebtOf(actor), 0);
        } else {
            pool.borrow(amount);
            assertEq(pool.debtBalanceOf(actor), normalized);
            assertLe(normalized, pool.maxBorrowOf(actor));
        }
    }

    function testFuzz_PartialRepaymentUsesFloorAndRejectsZeroBurn(uint256 index, uint256 seed) public {
        index = bound(index, WAD, 1e24);
        _setBorrowIndex(index);
        uint256 quantum = Math.ceilDiv(index, WAD);
        uint256 borrowAmount = quantum * 100 + 1e18;

        vm.prank(userOne);
        pool.borrow(borrowAmount);

        uint256 displayed = pool.debtBalanceOf(userOne);
        uint256 repayment = bound(seed, 1, displayed - 1);
        uint256 scaledBefore = pool.scaledDebtOf(userOne);
        uint256 totalScaledBefore = pool.totalScaledDebt();
        uint256 scaledBurn = Math.mulDiv(repayment, WAD, index, Math.Rounding.Floor);

        vm.prank(userOne);
        if (scaledBurn == 0) {
            vm.expectRevert(LendingPoolV1_2.ZeroScaledAmount.selector);
            pool.repay(repayment);
            assertEq(pool.scaledDebtOf(userOne), scaledBefore);
            assertEq(pool.totalScaledDebt(), totalScaledBefore);
        } else {
            pool.repay(repayment);
            assertEq(pool.scaledDebtOf(userOne), scaledBefore - scaledBurn);
            assertEq(pool.totalScaledDebt(), totalScaledBefore - scaledBurn);
            assertEq(pool.debtBalanceOf(userOne), Math.mulDiv(scaledBefore - scaledBurn, index, WAD));
        }
    }

    function testFuzz_FullRepaymentClearsAccount(uint256 index, uint256 amount) public {
        index = bound(index, WAD, 1e24);
        amount = bound(amount, 1, 1e24);
        _setBorrowIndex(index);

        vm.prank(userOne);
        pool.borrow(amount);
        uint256 displayed = pool.debtBalanceOf(userOne);
        uint256 scaled = pool.scaledDebtOf(userOne);
        uint256 aggregateBefore = pool.totalScaledDebt();

        vm.prank(userOne);
        pool.repay(type(uint256).max);

        assertEq(pool.scaledDebtOf(userOne), 0);
        assertEq(pool.debtBalanceOf(userOne), 0);
        assertEq(pool.totalScaledDebt(), aggregateBefore - scaled);
        assertGt(displayed, 0);
    }

    function testFuzz_MultipleBorrowerAggregateRounding(
        uint256 indexOne,
        uint256 indexTwo,
        uint256 indexThree,
        uint256 amountOne,
        uint256 amountTwo,
        uint256 amountThree
    ) public {
        indexOne = bound(indexOne, WAD, 1e20);
        indexTwo = bound(indexTwo, indexOne, 1e22);
        indexThree = bound(indexThree, indexTwo, 1e24);
        amountOne = bound(amountOne, 1, 1e20);
        amountTwo = bound(amountTwo, 1, 1e20);
        amountThree = bound(amountThree, 1, 1e20);

        _setBorrowIndex(indexOne);
        vm.prank(userOne);
        pool.borrow(amountOne);
        uint256 firstScaled = pool.scaledDebtOf(userOne);

        _setBorrowIndex(indexTwo);
        vm.prank(userTwo);
        pool.borrow(amountTwo);

        _setBorrowIndex(indexThree);
        vm.prank(userThree);
        pool.borrow(amountThree);

        uint256 scaledSum = pool.scaledDebtOf(userOne) + pool.scaledDebtOf(userTwo) + pool.scaledDebtOf(userThree);
        uint256 debtSum = pool.debtBalanceOf(userOne) + pool.debtBalanceOf(userTwo) + pool.debtBalanceOf(userThree);

        assertEq(pool.scaledDebtOf(userOne), firstScaled);
        assertEq(pool.totalScaledDebt(), scaledSum);
        assertGe(pool.totalDebt(), debtSum);
        assertLe(pool.totalDebt() - debtSum, 2);
    }

    function testFuzz_IndexMonotonicAcrossDebtAndLiquidityMutations(
        uint256 firstElapsed,
        uint256 secondElapsed,
        uint256 depositAmount,
        uint256 withdrawalAmount
    ) public {
        firstElapsed = bound(firstElapsed, 1, 365 days);
        secondElapsed = bound(secondElapsed, 1, 365 days);
        depositAmount = bound(depositAmount, 1, 1e24);
        withdrawalAmount = bound(withdrawalAmount, 1, 1e24);

        vm.prank(userOne);
        pool.borrow(1e24);
        uint256 scaled = pool.scaledDebtOf(userOne);
        uint256 initialIndex = pool.borrowIndex();

        vm.warp(block.timestamp + firstElapsed);
        priceFeed.setUpdatedAt(block.timestamp);
        uint256 beforeDeposit = pool.currentBorrowIndex();
        debtToken.mint(provider, depositAmount);
        vm.prank(provider);
        pool.depositLiquidity(depositAmount);

        assertGe(pool.borrowIndex(), initialIndex);
        assertEq(pool.borrowIndex(), beforeDeposit);
        assertEq(pool.scaledDebtOf(userOne), scaled);

        vm.warp(block.timestamp + secondElapsed);
        priceFeed.setUpdatedAt(block.timestamp);
        uint256 beforeWithdrawal = pool.currentBorrowIndex();
        vm.prank(provider);
        pool.withdrawLiquidity(withdrawalAmount);

        assertGe(pool.borrowIndex(), beforeDeposit);
        assertEq(pool.borrowIndex(), beforeWithdrawal);
        assertEq(pool.scaledDebtOf(userOne), scaled);

        uint256 quantum = Math.ceilDiv(pool.borrowIndex(), WAD);
        vm.prank(userOne);
        pool.repay(quantum);
        assertGt(scaled - pool.scaledDebtOf(userOne), 0);
        assertGe(pool.borrowIndex(), beforeWithdrawal);
    }

    function _depositCollateral(address user, uint256 amount) internal {
        vm.prank(user);
        pool.depositCollateral(amount);
    }

    function _setBorrowIndex(uint256 index) internal {
        stdstore.target(address(pool)).sig("borrowIndex()").checked_write(index);
        stdstore.target(address(pool)).sig("lastBorrowIndexUpdate()").checked_write(block.timestamp);
    }
}
