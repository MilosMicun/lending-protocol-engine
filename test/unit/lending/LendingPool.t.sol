// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {CollateralVault} from "../../../src/core/vault/CollateralVault.sol";
import {LendingPool} from "../../../src/core/lending/LendingPool.sol";

contract LendingPoolTest is Test {
    MockERC20 internal asset;
    CollateralVault internal vault;
    LendingPool internal pool;

    address internal user;
    address internal oracle;

    uint256 internal constant LTV_BPS = 7_000;
    uint256 internal constant LIQUIDATION_THRESHOLD_BPS = 8_000;
    uint256 internal constant LIQUIDATION_BONUS_BPS = 500;

    function setUp() public {
        user = makeAddr("user");
        oracle = makeAddr("oracle");

        asset = new MockERC20("Asset Token", "ASS");
        vault = new CollateralVault("Vault Share", "VSS", asset);

        pool = new LendingPool(
            oracle, address(vault), address(asset), LTV_BPS, LIQUIDATION_THRESHOLD_BPS, LIQUIDATION_BONUS_BPS
        );

        asset.mint(user, 1_000 ether);

        vm.prank(user);
        asset.approve(address(pool), type(uint256).max);
    }

    function test_DepositCollateral_UpdatesUserAndTotalCollateral() public {
        uint256 amount = 100 ether;

        uint256 userBalanceBefore = asset.balanceOf(user);
        uint256 expectedShares = vault.previewDeposit(amount);

        vm.prank(user);
        pool.depositCollateral(amount);

        uint256 userBalanceAfter = asset.balanceOf(user);

        assertEq(userBalanceAfter, userBalanceBefore - amount);
        assertEq(pool.collateralBalanceOf(user), amount);
        assertEq(pool.totalCollateral(), amount);
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

        assertEq(pool.collateralBalanceOf(user), 0);
        assertEq(pool.totalCollateral(), 0);
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
}
