// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {CollateralVault} from "../../../src/core/vault/CollateralVault.sol";
import {LendingPool} from "../../../src/core/lending/LendingPool.sol";

contract LendingPoolTest is Test {
    event Repaid(address indexed user, uint256 amount, uint256 newDebt);

    MockERC20 internal asset;
    CollateralVault internal vault;
    LendingPool internal pool;

    address internal user;
    address internal lp;
    address internal oracle;

    uint256 internal constant LTV_BPS = 7_000;
    uint256 internal constant LIQUIDATION_THRESHOLD_BPS = 8_000;
    uint256 internal constant LIQUIDATION_BONUS_BPS = 500;

    function setUp() public {
        user = makeAddr("user");
        lp = makeAddr("lp");
        oracle = makeAddr("oracle");

        asset = new MockERC20("Asset Token", "ASS");
        vault = new CollateralVault("Vault Share", "VSS", asset);

        pool = new LendingPool(
            oracle, address(vault), address(asset), LTV_BPS, LIQUIDATION_THRESHOLD_BPS, LIQUIDATION_BONUS_BPS
        );

        asset.mint(user, 1_000 ether);
        asset.mint(lp, 1_000 ether);

        vm.prank(user);
        asset.approve(address(pool), type(uint256).max);

        vm.prank(lp);
        asset.approve(address(pool), type(uint256).max);
    }

    function _setupBorrowedPosition(uint256 liquidityAmount, uint256 collateralAmount, uint256 borrowAmount) internal {
        vm.prank(lp);
        pool.depositLiquidity(liquidityAmount);

        vm.prank(user);
        pool.depositCollateral(collateralAmount);

        vm.prank(user);
        pool.borrow(borrowAmount);
    }

    function test_DepositCollateral_UpdatesUserAndTotalCollateralShares() public {
        uint256 amount = 100 ether;

        uint256 userBalanceBefore = asset.balanceOf(user);
        uint256 expectedShares = vault.previewDeposit(amount);

        vm.prank(user);
        pool.depositCollateral(amount);

        uint256 userBalanceAfter = asset.balanceOf(user);

        assertEq(userBalanceAfter, userBalanceBefore - amount);
        assertEq(pool.collateralSharesOf(user), expectedShares);
        assertEq(pool.totalCollateralShares(), expectedShares);
        assertEq(vault.balanceOf(address(pool)), expectedShares);
    }

    function test_WithdrawCollateral_TransfersAssetsBackAndUpdatesAccounting() public {
        uint256 amount = 100 ether;

        uint256 userBalanceBefore = asset.balanceOf(user);

        vm.prank(user);
        pool.depositCollateral(amount);

        vm.prank(user);
        pool.withdrawCollateral(amount);

        uint256 userBalanceAfter = asset.balanceOf(user);

        assertEq(pool.collateralSharesOf(user), 0);
        assertEq(pool.totalCollateralShares(), 0);
        assertEq(userBalanceAfter, userBalanceBefore);
        assertEq(vault.balanceOf(address(pool)), 0);
    }

    function test_WithdrawCollateral_Reverts_WhenAmountExceedsUserCollateral() public {
        uint256 depositAmount = 100 ether;
        uint256 withdrawAmount = 101 ether;

        vm.prank(user);
        pool.depositCollateral(depositAmount);

        vm.prank(user);
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.withdrawCollateral(withdrawAmount);
    }

    function test_DepositLiquidity_UpdatesUserAndTotalLiquidity() public {
        uint256 amount = 100 ether;

        vm.prank(lp);
        pool.depositLiquidity(amount);

        assertEq(pool.liquidityBalanceOf(lp), amount);
        assertEq(pool.totalLiquidity(), amount);
        assertEq(asset.balanceOf(address(pool)), amount);
    }

    function test_WithdrawLiquidity_TransfersAssetsBackAndUpdatesAccounting() public {
        uint256 amount = 100 ether;

        vm.prank(lp);
        pool.depositLiquidity(amount);

        uint256 lpBalanceBefore = asset.balanceOf(lp);

        vm.prank(lp);
        pool.withdrawLiquidity(amount);

        assertEq(pool.liquidityBalanceOf(lp), 0);
        assertEq(pool.totalLiquidity(), 0);
        assertEq(pool.availableLiquidity(), 0);
        assertEq(asset.balanceOf(lp), lpBalanceBefore + amount);
        assertEq(asset.balanceOf(address(pool)), 0);
    }

    function test_WithdrawLiquidity_RevertsIfAmountExceedsUserLiquidityBalance() public {
        uint256 depositAmount = 100 ether;
        uint256 withdrawAmount = 101 ether;

        vm.prank(lp);
        pool.depositLiquidity(depositAmount);

        vm.prank(lp);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.withdrawLiquidity(withdrawAmount);
    }

    function test_WithdrawLiquidity_RevertsIfAmountExceedsAvailableLiquidity() public {
        uint256 liquidityAmount = 1_000 ether;
        uint256 collateralAmount = 1_000 ether;
        uint256 borrowAmount = 700 ether;
        uint256 withdrawAmount = 400 ether;

        vm.prank(lp);
        pool.depositLiquidity(liquidityAmount);

        vm.prank(user);
        pool.depositCollateral(collateralAmount);

        vm.prank(user);
        pool.borrow(borrowAmount);

        vm.prank(lp);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.withdrawLiquidity(withdrawAmount);
    }

    function test_Borrow_UpdatesDebtAndTransfersAsset() public {
        uint256 liquidityAmount = 1_000 ether;
        uint256 collateralAmount = 100 ether;
        uint256 borrowAmount = 50 ether;

        vm.prank(lp);
        pool.depositLiquidity(liquidityAmount);

        vm.prank(user);
        pool.depositCollateral(collateralAmount);

        uint256 userBalanceBefore = asset.balanceOf(user);

        vm.prank(user);
        pool.borrow(borrowAmount);

        assertEq(pool.debtBalanceOf(user), borrowAmount);
        assertEq(pool.totalDebt(), borrowAmount);
        assertEq(asset.balanceOf(user), userBalanceBefore + borrowAmount);
        assertEq(pool.availableLiquidity(), liquidityAmount - borrowAmount);
    }

    function test_Borrow_RevertsIfZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.borrow(0);
    }

    function test_Borrow_RevertsIfNoCollateral() public {
        uint256 liquidityAmount = 1_000 ether;
        uint256 borrowAmount = 50 ether;

        vm.prank(lp);
        pool.depositLiquidity(liquidityAmount);

        vm.prank(user);
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.borrow(borrowAmount);
    }

    function test_Borrow_RevertsIfExceedsLtv() public {
        uint256 liquidityAmount = 1_000 ether;
        uint256 collateralAmount = 100 ether;
        uint256 borrowAmount = 71 ether;

        vm.prank(lp);
        pool.depositLiquidity(liquidityAmount);

        vm.prank(user);
        pool.depositCollateral(collateralAmount);

        vm.prank(user);
        vm.expectRevert(LendingPool.BorrowExceedsLimit.selector);
        pool.borrow(borrowAmount);
    }

    function test_Borrow_RevertsIfInsufficientLiquidity() public {
        uint256 liquidityAmount = 10 ether;
        uint256 collateralAmount = 100 ether;
        uint256 borrowAmount = 50 ether;

        vm.prank(lp);
        pool.depositLiquidity(liquidityAmount);

        vm.prank(user);
        pool.depositCollateral(collateralAmount);

        vm.prank(user);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.borrow(borrowAmount);
    }

    function test_Borrow_AllowsBorrowUpToMaxLtv() public {
        uint256 liquidityAmount = 1_000 ether;
        uint256 collateralAmount = 100 ether;
        uint256 borrowAmount = 70 ether;

        vm.prank(lp);
        pool.depositLiquidity(liquidityAmount);

        vm.prank(user);
        pool.depositCollateral(collateralAmount);

        vm.prank(user);
        pool.borrow(borrowAmount);

        assertEq(pool.debtBalanceOf(user), borrowAmount);
        assertEq(pool.totalDebt(), borrowAmount);
        assertEq(pool.availableLiquidity(), liquidityAmount - borrowAmount);
    }

    function test_Borrow_AccumulatesDebtAcrossMultipleBorrows() public {
        uint256 liquidityAmount = 1_000 ether;
        uint256 collateralAmount = 100 ether;
        uint256 firstBorrow = 30 ether;
        uint256 secondBorrow = 40 ether;

        vm.prank(lp);
        pool.depositLiquidity(liquidityAmount);

        vm.prank(user);
        pool.depositCollateral(collateralAmount);

        vm.prank(user);
        pool.borrow(firstBorrow);

        vm.prank(user);
        pool.borrow(secondBorrow);

        assertEq(pool.debtBalanceOf(user), firstBorrow + secondBorrow);
        assertEq(pool.totalDebt(), firstBorrow + secondBorrow);
        assertEq(pool.availableLiquidity(), liquidityAmount - firstBorrow - secondBorrow);
    }

    function test_Repay_RevertsIfZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.repay(0);
    }

    function test_Repay_RevertsIfUserHasNoDebt() public {
        vm.prank(user);
        vm.expectRevert(LendingPool.NoDebt.selector);
        pool.repay(1 ether);
    }

    function test_Repay_ReducesUserDebtAndTotalDebt_OnPartialRepay() public {
        _setupBorrowedPosition(1000 ether, 100 ether, 50 ether);

        vm.prank(user);
        pool.repay(20 ether);

        assertEq(pool.debtBalanceOf(user), 30 ether);
        assertEq(pool.totalDebt(), 30 ether);
        assertEq(pool.availableLiquidity(), 970 ether);
        assertEq(asset.balanceOf(address(pool)), 1000 ether - 50 ether + 20 ether);
    }

    function test_Repay_ClearsUserDebt_OnFullRepay() public {
        _setupBorrowedPosition(1000 ether, 100 ether, 50 ether);

        vm.prank(user);
        pool.repay(50 ether);

        assertEq(pool.debtBalanceOf(user), 0);
        assertEq(pool.totalDebt(), 0);
        assertEq(pool.availableLiquidity(), 1000 ether);
        assertEq(asset.balanceOf(address(pool)), 1000 ether - 50 ether + 50 ether);
    }

    function test_Repay_OverpayOnlyTakesDebtAmount() public {
        _setupBorrowedPosition(1000 ether, 100 ether, 50 ether);

        vm.prank(user);
        pool.repay(100 ether);

        assertEq(pool.debtBalanceOf(user), 0);
        assertEq(pool.totalDebt(), 0);
        assertEq(pool.availableLiquidity(), 1000 ether);
        assertEq(asset.balanceOf(address(pool)), 1000 ether - 50 ether + 50 ether);
        assertEq(asset.balanceOf(user), 900 ether);
    }

    function test_Repay_IncreasesAvailableLiquidity() public {
        _setupBorrowedPosition(1000 ether, 100 ether, 50 ether);

        uint256 beforeLiquidity = pool.availableLiquidity();

        uint256 repayAmount = 50 ether;

        vm.prank(user);
        pool.repay(repayAmount);

        uint256 afterLiquidity = pool.availableLiquidity();

        assertEq(afterLiquidity, beforeLiquidity + repayAmount);
    }

    function test_Repay_EmitsRepaidEvent() public {
        _setupBorrowedPosition(1000 ether, 100 ether, 50 ether);

        uint256 repayAmount = 20 ether;
        uint256 expectedNewDebt = 30 ether;

        vm.prank(user);
        vm.expectEmit(true, false, false, true);

        emit Repaid(user, repayAmount, expectedNewDebt);

        pool.repay(repayAmount);
    }
}
