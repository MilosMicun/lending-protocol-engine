// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {LendingPoolProxyFixture} from "../helpers/LendingPoolProxyFixture.sol";

import {CollateralVault} from "../../src/core/vault/CollateralVault.sol";
import {LendingPool} from "../../src/core/lending/LendingPool.sol";

contract LendingPoolFuzzTest is Test, LendingPoolProxyFixture {
    MockERC20 internal asset;
    CollateralVault internal vault;
    LendingPool internal pool;
    LendingPool internal poolImplementation;
    MockV3Aggregator internal priceFeed;

    address internal user;
    address internal lp;
    address internal liquidator;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    uint256 internal constant LTV_BPS = 7_000;
    uint256 internal constant LIQUIDATION_THRESHOLD_BPS = 8_000;
    uint256 internal constant LIQUIDATION_BONUS_BPS = 500;
    uint256 internal constant MAX_PRICE_STALENESS = 1 days;

    uint256 internal constant BASE_BORROW_RATE = 0.05e18;
    uint256 internal constant BORROW_RATE_SLOPE = 0.2e18;

    uint8 internal constant PRICE_DECIMALS = 8;
    int256 internal constant INITIAL_PRICE = 1e8;

    function setUp() public {
        user = makeAddr("user");
        lp = makeAddr("lp");
        liquidator = makeAddr("liquidator");

        asset = new MockERC20("Asset Token", "ASS");
        vault = new CollateralVault("Vault Share", "VSS", asset);
        priceFeed = new MockV3Aggregator(PRICE_DECIMALS, INITIAL_PRICE, block.timestamp);

        LendingPoolProxyConfig memory config = LendingPoolProxyConfig({
            priceFeed: address(priceFeed),
            vault: address(vault),
            debtAsset: address(asset),
            maxPriceStaleness: MAX_PRICE_STALENESS,
            ltvBps: LTV_BPS,
            liquidationThresholdBps: LIQUIDATION_THRESHOLD_BPS,
            liquidationBonusBps: LIQUIDATION_BONUS_BPS,
            baseBorrowRate: BASE_BORROW_RATE,
            borrowRateSlope: BORROW_RATE_SLOPE,
            initialUpgradeAuthority: address(this)
        });

        (pool, poolImplementation) = _deployLendingPoolProxy(config);

        asset.mint(user, 1_000 ether);
        asset.mint(lp, 1_000 ether);
        asset.mint(liquidator, 1_000 ether);

        vm.prank(user);
        asset.approve(address(pool), type(uint256).max);

        vm.prank(lp);
        asset.approve(address(pool), type(uint256).max);

        vm.prank(liquidator);
        asset.approve(address(pool), type(uint256).max);
    }

    function test_SetUp() public view {
        assertEq(asset.balanceOf(user), 1_000 ether);
        assertEq(asset.balanceOf(lp), 1_000 ether);
        assertEq(asset.balanceOf(liquidator), 1_000 ether);
        assertEq(pool.borrowIndex(), WAD);
    }

    function testFuzz_Borrow_UpdatesAccountingCorrectly(uint256 borrowAmount) public {
        uint256 liquidityAmount = 1_000 ether;
        uint256 collateralAmount = 100 ether;

        vm.prank(lp);
        pool.depositLiquidity(liquidityAmount);

        vm.prank(user);
        pool.depositCollateral(collateralAmount);

        uint256 maxBorrow = pool.maxBorrowOf(user);
        borrowAmount = bound(borrowAmount, 1, maxBorrow);

        uint256 userBalanceBefore = asset.balanceOf(user);

        vm.prank(user);
        pool.borrow(borrowAmount);

        assertEq(pool.debtBalanceOf(user), borrowAmount);
        assertEq(pool.totalDebt(), borrowAmount);
        assertEq(pool.availableLiquidity(), liquidityAmount - borrowAmount);
        assertEq(asset.balanceOf(user), userBalanceBefore + borrowAmount);
    }

    function testFuzz_Borrow_RevertsIfExceedsMaxBorrow(uint256 borrowAmount) public {
        uint256 liquidityAmount = 1_000 ether;
        uint256 collateralAmount = 100 ether;

        vm.prank(lp);
        pool.depositLiquidity(liquidityAmount);

        vm.prank(user);
        pool.depositCollateral(collateralAmount);

        uint256 maxBorrow = pool.maxBorrowOf(user);
        borrowAmount = bound(borrowAmount, maxBorrow + 1, liquidityAmount);

        vm.prank(user);
        vm.expectRevert(LendingPool.BorrowExceedsLimit.selector);
        pool.borrow(borrowAmount);
    }

    function testFuzz_WithdrawCollateral_SuccessLeavesPositionHealthyAfterDonation(
        uint256 depositAmount,
        uint256 donationAmount,
        uint256 borrowAmount,
        uint256 withdrawAmount
    ) public {
        depositAmount = bound(depositAmount, 1, 1_000);
        donationAmount = bound(donationAmount, 3, 1_000);

        vm.prank(lp);
        pool.depositLiquidity(10_000);

        vm.prank(user);
        pool.depositCollateral(depositAmount);

        vm.prank(user);
        assertTrue(asset.transfer(address(vault), donationAmount));

        uint256 maxBorrow = pool.maxBorrowOf(user);
        borrowAmount = bound(borrowAmount, 1, maxBorrow);

        vm.prank(user);
        pool.borrow(borrowAmount);

        uint256 userSharesBefore = pool.collateralSharesOf(user);
        uint256 userAssetsBefore = vault.convertToAssets(userSharesBefore);
        withdrawAmount = bound(withdrawAmount, 1, userAssetsBefore);
        uint256 sharesNeeded = vault.previewWithdraw(withdrawAmount);

        vm.prank(user);
        try pool.withdrawCollateral(withdrawAmount) {
            uint256 remainingShares = pool.collateralSharesOf(user);
            uint256 remainingAssets = vault.convertToAssets(remainingShares);
            uint256 remainingValue = remainingAssets;
            uint256 adjustedRemainingValue = remainingValue * LIQUIDATION_THRESHOLD_BPS / BPS;
            uint256 expectedHealthFactor = adjustedRemainingValue * WAD / borrowAmount;

            assertEq(remainingShares, userSharesBefore - sharesNeeded);
            assertEq(pool.getCollateralAssets(user), remainingAssets);
            assertEq(pool.getHealthFactor(user), expectedHealthFactor);
            assertGe(expectedHealthFactor, WAD);
        } catch (bytes memory reason) {
            bytes4 selector;
            assembly {
                selector := mload(add(reason, 0x20))
            }
            assertEq(selector, LendingPool.HealthFactorTooLow.selector);
        }
    }

    function testFuzz_Repay_ReducesDebtCorrectly(uint256 borrowAmount, uint256 repayAmount) public {
        uint256 liquidityAmount = 1_000 ether;
        uint256 collateralAmount = 100 ether;

        vm.prank(lp);
        pool.depositLiquidity(liquidityAmount);

        vm.prank(user);
        pool.depositCollateral(collateralAmount);

        uint256 maxBorrow = pool.maxBorrowOf(user);
        borrowAmount = bound(borrowAmount, 1, maxBorrow);

        vm.prank(user);
        pool.borrow(borrowAmount);

        repayAmount = bound(repayAmount, 1, borrowAmount);

        vm.prank(user);
        pool.repay(repayAmount);

        uint256 expectedDebt = borrowAmount - repayAmount;

        assertEq(pool.debtBalanceOf(user), expectedDebt);
        assertEq(pool.totalDebt(), expectedDebt);
        assertEq(pool.availableLiquidity(), liquidityAmount - expectedDebt);

        if (repayAmount == borrowAmount) {
            assertEq(pool.scaledDebtOf(user), 0);
            assertEq(pool.totalScaledDebt(), 0);
        } else {
            assertGt(pool.scaledDebtOf(user), 0);
            assertGt(pool.totalScaledDebt(), 0);
        }
    }

    function testFuzz_Repay_OverpayOnlyRepaysOutstandingDebt(uint256 borrowAmount, uint256 repayAmount) public {
        uint256 liquidityAmount = 1_000 ether;
        uint256 collateralAmount = 100 ether;

        vm.prank(lp);
        pool.depositLiquidity(liquidityAmount);

        vm.prank(user);
        pool.depositCollateral(collateralAmount);

        uint256 maxBorrow = pool.maxBorrowOf(user);

        borrowAmount = bound(borrowAmount, 1, maxBorrow);
        repayAmount = bound(repayAmount, borrowAmount + 1, type(uint128).max);

        vm.prank(user);
        pool.borrow(borrowAmount);

        uint256 userBalanceBefore = asset.balanceOf(user);

        vm.prank(user);
        pool.repay(repayAmount);

        assertEq(pool.debtBalanceOf(user), 0);
        assertEq(pool.totalDebt(), 0);
        assertEq(pool.scaledDebtOf(user), 0);
        assertEq(pool.totalScaledDebt(), 0);
        assertEq(pool.availableLiquidity(), liquidityAmount);
        assertEq(asset.balanceOf(user), userBalanceBefore - borrowAmount);
    }

    function test_RepayAfterAccrual_ZeroScaledRepaymentTransfersTokensWithoutReducingDebt() public {
        uint256 liquidityAmount = 1_000 ether;
        uint256 collateralAmount = 100 ether;
        uint256 borrowAmount = 50 ether;
        uint256 repayAmount = 1;

        vm.prank(lp);
        pool.depositLiquidity(liquidityAmount);

        vm.prank(user);
        pool.depositCollateral(collateralAmount);

        vm.prank(user);
        pool.borrow(borrowAmount);

        vm.warp(block.timestamp + 1 days);

        uint256 accruedBorrowIndex = pool.currentBorrowIndex();
        uint256 scaledDebtBefore = pool.scaledDebtOf(user);
        uint256 totalScaledDebtBefore = pool.totalScaledDebt();
        uint256 debtBefore = pool.debtBalanceOf(user);
        uint256 userBalanceBefore = asset.balanceOf(user);
        uint256 poolBalanceBefore = asset.balanceOf(address(pool));
        uint256 expectedScaledRepay = repayAmount * WAD / accruedBorrowIndex;

        assertGt(repayAmount, 0);
        assertLt(repayAmount, debtBefore);
        assertGt(accruedBorrowIndex, WAD);
        assertEq(expectedScaledRepay, 0);

        vm.prank(user);
        pool.repay(repayAmount);

        uint256 debtAfter = pool.debtBalanceOf(user);
        uint256 scaledDebtAfter = pool.scaledDebtOf(user);

        assertEq(pool.borrowIndex(), accruedBorrowIndex);
        assertEq(asset.balanceOf(user), userBalanceBefore - repayAmount);
        assertEq(asset.balanceOf(address(pool)), poolBalanceBefore + repayAmount);
        assertEq(scaledDebtAfter, scaledDebtBefore);
        assertEq(pool.totalScaledDebt(), totalScaledDebtBefore);
        assertEq(debtAfter, debtBefore);

        // Exact equality above proves that the former non-strict assertions would have passed without a reduction.
    }

    function testFuzz_RepayAfterAccrual_MatchesScaledRoundingAndDoesNotUnderflow(
        uint256 borrowAmount,
        uint256 repayAmount,
        uint256 timeElapsed
    ) public {
        uint256 liquidityAmount = 1_000 ether;
        uint256 collateralAmount = 100 ether;

        vm.prank(lp);
        pool.depositLiquidity(liquidityAmount);

        vm.prank(user);
        pool.depositCollateral(collateralAmount);

        uint256 maxBorrow = pool.maxBorrowOf(user);
        borrowAmount = bound(borrowAmount, 1 ether, maxBorrow);

        vm.prank(user);
        pool.borrow(borrowAmount);

        timeElapsed = bound(timeElapsed, 1, MAX_PRICE_STALENESS - 1);

        vm.warp(block.timestamp + timeElapsed);
        priceFeed.setUpdatedAt(block.timestamp);

        uint256 accruedBorrowIndex = pool.currentBorrowIndex();
        uint256 debtBefore = pool.debtBalanceOf(user);
        uint256 scaledDebtBefore = pool.scaledDebtOf(user);
        uint256 totalScaledDebtBefore = pool.totalScaledDebt();

        assertGt(debtBefore, borrowAmount);

        repayAmount = bound(repayAmount, 1, debtBefore);

        uint256 expectedScaledRepay = repayAmount * WAD / accruedBorrowIndex;
        uint256 userBalanceBefore = asset.balanceOf(user);
        uint256 poolBalanceBefore = asset.balanceOf(address(pool));

        vm.prank(user);
        pool.repay(repayAmount);

        uint256 debtAfter = pool.debtBalanceOf(user);

        assertEq(pool.borrowIndex(), accruedBorrowIndex);
        assertEq(asset.balanceOf(user), userBalanceBefore - repayAmount);
        assertEq(asset.balanceOf(address(pool)), poolBalanceBefore + repayAmount);
        assertEq(pool.totalDebt(), debtAfter);
        assertEq(pool.availableLiquidity(), liquidityAmount - debtAfter);

        if (repayAmount == debtBefore) {
            assertEq(pool.scaledDebtOf(user), 0);
            assertEq(pool.totalScaledDebt(), 0);
            assertLt(pool.scaledDebtOf(user), scaledDebtBefore);
            assertLt(pool.totalScaledDebt(), totalScaledDebtBefore);
            assertLt(debtAfter, debtBefore);
        } else {
            assertGt(pool.scaledDebtOf(user), 0);
            assertGt(pool.totalScaledDebt(), 0);

            if (expectedScaledRepay == 0) {
                assertEq(pool.scaledDebtOf(user), scaledDebtBefore);
                assertEq(pool.totalScaledDebt(), totalScaledDebtBefore);
                assertEq(debtAfter, debtBefore);
            } else {
                assertEq(pool.scaledDebtOf(user), scaledDebtBefore - expectedScaledRepay);
                assertEq(pool.totalScaledDebt(), totalScaledDebtBefore - expectedScaledRepay);
                assertLt(pool.scaledDebtOf(user), scaledDebtBefore);
                assertLt(pool.totalScaledDebt(), totalScaledDebtBefore);
                assertLt(debtAfter, debtBefore);
            }
        }
    }

    function testFuzz_Liquidate_ReducesDebtAndCollateral(uint256 repayAmount) public {
        uint256 liquidityAmount = 1_000 ether;
        uint256 collateralAmount = 100 ether;
        uint256 borrowAmount = 70 ether;

        vm.prank(lp);
        pool.depositLiquidity(liquidityAmount);

        vm.prank(user);
        pool.depositCollateral(collateralAmount);

        vm.prank(user);
        pool.borrow(borrowAmount);

        priceFeed.setAnswer(5e7);

        uint256 debtBefore = pool.debtBalanceOf(user);
        uint256 collateralBefore = pool.collateralSharesOf(user);

        repayAmount = bound(repayAmount, 1, debtBefore);

        vm.prank(liquidator);
        pool.liquidate(user, repayAmount);

        uint256 debtAfter = pool.debtBalanceOf(user);
        uint256 collateralAfter = pool.collateralSharesOf(user);

        assertLt(debtAfter, debtBefore);
        assertLt(collateralAfter, collateralBefore);
        assertEq(pool.totalDebt(), debtAfter);
        assertEq(pool.availableLiquidity(), liquidityAmount - debtAfter);
    }

    function testFuzz_Liquidate_RevertsIfPositionIsHealthy(uint256 repayAmount) public {
        uint256 liquidityAmount = 1_000 ether;
        uint256 collateralAmount = 100 ether;
        uint256 borrowAmount = 50 ether;

        vm.prank(lp);
        pool.depositLiquidity(liquidityAmount);

        vm.prank(user);
        pool.depositCollateral(collateralAmount);

        vm.prank(user);
        pool.borrow(borrowAmount);

        repayAmount = bound(repayAmount, 1, borrowAmount);

        vm.prank(liquidator);
        vm.expectRevert(LendingPool.PositionNotLiquidatable.selector);
        pool.liquidate(user, repayAmount);
    }

    function testFuzz_Liquidate_CapsRepayWhenCollateralCannotCoverDebtPlusBonus(uint256 repayAmount) public {
        uint256 liquidityAmount = 1_000 ether;
        uint256 collateralAmount = 100 ether;
        uint256 borrowAmount = 70 ether;

        vm.prank(lp);
        pool.depositLiquidity(liquidityAmount);

        vm.prank(user);
        pool.depositCollateral(collateralAmount);

        vm.prank(user);
        pool.borrow(borrowAmount);

        priceFeed.setAnswer(5e7);

        uint256 debtBefore = pool.debtBalanceOf(user);

        // priceFeed answer is 5e7 with 8 decimals = 0.5 WAD,
        // so collateral value is exactly half of collateralAmount.
        uint256 collateralValue = collateralAmount / 2;

        uint256 maxRepayCoveredByCollateral = collateralValue * BPS / (BPS + LIQUIDATION_BONUS_BPS);

        repayAmount = bound(repayAmount, maxRepayCoveredByCollateral + 1, debtBefore);

        vm.prank(liquidator);
        pool.liquidate(user, repayAmount);

        assertGt(pool.debtBalanceOf(user), 0);
        assertLt(pool.debtBalanceOf(user), debtBefore);
        assertEq(pool.collateralSharesOf(user), 0);
        assertEq(pool.totalCollateralShares(), 0);
    }

    function testFuzz_BorrowAndRepay_AvailableLiquidityRemainsConsistent(uint256 borrowAmount, uint256 repayAmount)
        public
    {
        uint256 liquidityAmount = 1_000 ether;
        uint256 collateralAmount = 100 ether;

        vm.prank(lp);
        pool.depositLiquidity(liquidityAmount);

        vm.prank(user);
        pool.depositCollateral(collateralAmount);

        uint256 maxBorrow = pool.maxBorrowOf(user);
        borrowAmount = bound(borrowAmount, 1, maxBorrow);

        vm.prank(user);
        pool.borrow(borrowAmount);

        repayAmount = bound(repayAmount, 1, borrowAmount);

        vm.prank(user);
        pool.repay(repayAmount);

        uint256 remainingDebt = borrowAmount - repayAmount;

        assertEq(pool.totalDebt(), remainingDebt);
        assertEq(pool.availableLiquidity(), liquidityAmount - remainingDebt);
        assertLe(pool.availableLiquidity(), pool.totalLiquidity());
    }
}
