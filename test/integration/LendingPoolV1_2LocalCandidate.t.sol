// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LendingPoolProxyFixture} from "../helpers/LendingPoolProxyFixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

import {LendingPoolV1_2} from "../../src/core/lending/LendingPoolV1_2.sol";
import {CollateralVault} from "../../src/core/vault/CollateralVault.sol";
import {BorrowIndexMath} from "../../src/lib/BorrowIndexMath.sol";

contract LendingPoolV1_2LocalCandidateIntegrationTest is Test, LendingPoolProxyFixture {
    uint256 internal constant WAD = 1e18;

    MockERC20 internal collateralToken;
    MockERC20 internal debtToken;
    CollateralVault internal vault;
    MockV3Aggregator internal priceFeed;
    LendingPoolV1_2 internal pool;
    LendingPoolV1_2 internal implementation;

    address internal providerOne = makeAddr("providerOne");
    address internal providerTwo = makeAddr("providerTwo");
    address internal borrowerOne = makeAddr("borrowerOne");
    address internal borrowerTwo = makeAddr("borrowerTwo");
    address internal liquidator = makeAddr("liquidator");

    function setUp() public {
        collateralToken = new MockERC20("Collateral", "COL");
        debtToken = new MockERC20("Debt", "DEBT");
        vault = new CollateralVault("Vault Share", "VSH", collateralToken);
        priceFeed = new MockV3Aggregator(8, 1e8, block.timestamp);
        implementation = new LendingPoolV1_2();

        pool = LendingPoolV1_2(
            address(
                _deployLendingPoolProxy(
                    implementation,
                    LendingPoolProxyConfig({
                        priceFeed: address(priceFeed),
                        vault: address(vault),
                        debtAsset: address(debtToken),
                        maxPriceStaleness: 1 days,
                        ltvBps: 7_000,
                        liquidationThresholdBps: 8_000,
                        liquidationBonusBps: 500,
                        baseBorrowRate: 0.05e18,
                        borrowRateSlope: 0.2e18,
                        initialUpgradeAuthority: address(this)
                    })
                )
            )
        );

        address[5] memory actors = [providerOne, providerTwo, borrowerOne, borrowerTwo, liquidator];
        for (uint256 i; i < actors.length; ++i) {
            collateralToken.mint(actors[i], 10_000 ether);
            debtToken.mint(actors[i], 10_000 ether);
            vm.startPrank(actors[i]);
            collateralToken.approve(address(pool), type(uint256).max);
            debtToken.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    function test_LocalProxyEndToEndKeepsRayAndRoundedAccountingConsistent() public {
        vm.prank(providerOne);
        pool.depositLiquidity(2_000 ether);
        vm.prank(borrowerOne);
        pool.depositCollateral(500 ether);
        vm.prank(borrowerTwo);
        pool.depositCollateral(400 ether);

        vm.prank(borrowerOne);
        pool.borrow(250 ether);
        uint256 firstScaled = pool.scaledDebtOf(borrowerOne);
        uint256 rateBeforeBoundary = pool.currentBorrowRate();
        uint256 storedBeforeBoundary = pool.borrowIndex();

        vm.warp(block.timestamp + 30 days);
        priceFeed.setUpdatedAt(block.timestamp);
        uint256 expectedBoundary = BorrowIndexMath.accrueIndex(storedBeforeBoundary, rateBeforeBoundary, 30 days);

        vm.prank(providerTwo);
        pool.depositLiquidity(1_000 ether);
        assertEq(pool.borrowIndex(), expectedBoundary);
        assertEq(pool.scaledDebtOf(borrowerOne), firstScaled);

        vm.prank(borrowerTwo);
        pool.borrow(180 ether);
        uint256 secondScaled = pool.scaledDebtOf(borrowerTwo);
        assertEq(secondScaled, Math.mulDiv(180 ether, WAD, pool.borrowIndex(), Math.Rounding.Ceil));

        uint256 repayment = 25 ether;
        uint256 firstScaledBeforeRepay = pool.scaledDebtOf(borrowerOne);
        uint256 expectedBurn = Math.mulDiv(repayment, WAD, pool.borrowIndex(), Math.Rounding.Floor);
        vm.prank(borrowerOne);
        pool.repay(repayment);

        assertEq(pool.scaledDebtOf(borrowerOne), firstScaledBeforeRepay - expectedBurn);
        assertEq(pool.totalScaledDebt(), pool.scaledDebtOf(borrowerOne) + pool.scaledDebtOf(borrowerTwo));

        uint256 sumDebt = pool.debtBalanceOf(borrowerOne) + pool.debtBalanceOf(borrowerTwo);
        assertGe(pool.totalDebt(), sumDebt);
        assertLe(pool.totalDebt() - sumDebt, 1);
        assertEq(pool.version(), "1.2");
    }

    function test_LocalCandidateExposesNoMigrationOrReinitializerEntryPoint() public {
        uint256 indexBefore = pool.borrowIndex();
        uint256 timestampBefore = pool.lastBorrowIndexUpdate();

        (bool migrated,) = address(pool).call(abi.encodeWithSignature("migrateLegacyAccrual(uint256,bytes32)"));
        (bool reinitialized,) = address(pool).call(abi.encodeWithSignature("initializeV2()"));

        assertFalse(migrated);
        assertFalse(reinitialized);
        assertEq(pool.borrowIndex(), indexBefore);
        assertEq(pool.lastBorrowIndexUpdate(), timestampBefore);
    }

    function test_ImplementationRemainsUninitializedAndCustodyFree() public view {
        assertEq(debtToken.balanceOf(address(implementation)), 0);
        assertEq(collateralToken.balanceOf(address(implementation)), 0);
        assertEq(vault.balanceOf(address(implementation)), 0);
        assertEq(implementation.totalLiquidity(), 0);
        assertEq(implementation.totalScaledDebt(), 0);
    }
}
