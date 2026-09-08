// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {HistoricalLendingPoolV1InterestFixture} from "../../helpers/HistoricalLendingPoolV1InterestFixture.sol";
import {LendingPoolProxyFixture} from "../../helpers/LendingPoolProxyFixture.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";

import {LendingPool} from "../../../src/core/lending/LendingPool.sol";
import {LendingPoolV1_1} from "../../../src/core/lending/LendingPoolV1_1.sol";
import {LendingPoolV1_2} from "../../../src/core/lending/LendingPoolV1_2.sol";
import {CollateralVault} from "../../../src/core/vault/CollateralVault.sol";
import {BorrowIndexMath} from "../../../src/lib/BorrowIndexMath.sol";

contract MockSixDecimalERC20 is MockERC20 {
    constructor() MockERC20("Six Decimal Debt", "SIX") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract BorrowAdmissionMathHarness is LendingPool {
    function scaledToDebtForBorrowAdmission(uint256 scaledAmount, uint256 index) external pure returns (uint256) {
        return _scaledToDebtForBorrowAdmission(scaledAmount, index);
    }
}

contract LendingPoolV1_2Test is Test, LendingPoolProxyFixture {
    using stdStorage for StdStorage;

    event Borrowed(address indexed user, uint256 amount, uint256 newDebt);
    event Repaid(address indexed user, uint256 amount, uint256 newDebt);
    event BorrowIndexUpdated(uint256 newBorrowIndex);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant MAX_ELAPSED = 100 * YEAR;
    uint256 internal constant MAX_DEBT_QUANTUM = 1_000_000;
    uint256 internal constant MAX_SUPPORTED_INDEX = MAX_DEBT_QUANTUM * WAD;
    uint256 internal constant MAX_BORROW_INDEX_OUTPUT = 26881128798378344518912877811038280859564355321045156268014032;
    uint256 internal constant LEGACY_OVERFLOW_INDEX = 2_500_000_000_000_000_000;
    uint256 internal constant LEGACY_PRE_BORROW_SCALED_DEBT =
        46_316_835_694_926_478_169_428_394_003_475_163_141_307_993_866_256_225_615_783;
    uint256 internal constant LEGACY_PRE_BORROW_DISPLAYED_DEBT =
        115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457;
    uint256 internal constant LEGACY_POST_BORROW_DISPLAYED_DEBT =
        115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_460;

    MockERC20 internal collateralToken;
    MockERC20 internal debtToken;
    CollateralVault internal vault;
    MockV3Aggregator internal priceFeed;
    LendingPoolV1_2 internal pool;
    LendingPoolV1_2 internal implementation;

    address internal borrower = makeAddr("borrower");
    address internal borrowerTwo = makeAddr("borrowerTwo");
    address internal borrowerThree = makeAddr("borrowerThree");
    address internal provider = makeAddr("provider");
    address internal liquidator = makeAddr("liquidator");

    function setUp() public {
        collateralToken = new MockERC20("Collateral", "COL");
        debtToken = new MockERC20("Debt", "DEBT");
        vault = new CollateralVault("Vault Share", "VSH", collateralToken);
        priceFeed = new MockV3Aggregator(8, 1e8, block.timestamp);

        (pool, implementation) = _newV12Pool(0.2e18, 0);
        _fundAndApproveActors(pool);
        _provideLiquidity(pool, 1_000_000 ether);
        _provideCollateral(pool, borrower, 10_000 ether);
        _provideCollateral(pool, borrowerTwo, 10_000 ether);
        _provideCollateral(pool, borrowerThree, 10_000 ether);
    }

    function test_VersionSeparationAndOldFormulaRemainDistinct() public {
        LendingPool v1 = _newPool(new LendingPool(), 0.2e18, 0);
        LendingPool v11 = _newPool(new LendingPoolV1_1(), 0.2e18, 0);
        LendingPool v12 = _newPool(new LendingPoolV1_2(), 0.2e18, 0);

        _fundAndApproveActors(v1);
        _fundAndApproveActors(v11);
        _fundAndApproveActors(v12);
        _openPosition(v1, 1_000 ether, 1_000 ether, 100 ether);
        _openPosition(v11, 1_000 ether, 1_000 ether, 100 ether);
        _openPosition(v12, 1_000 ether, 1_000 ether, 100 ether);

        uint256 start = block.timestamp;
        vm.warp(start + YEAR);

        uint256 oldFactor = WAD / 5;
        uint256 oldExpected = WAD + oldFactor + oldFactor * oldFactor / (2 * WAD);
        uint256 rayExpected = BorrowIndexMath.accrueIndex(WAD, WAD / 5, YEAR);

        assertEq(v1.currentBorrowIndex(), oldExpected);
        assertEq(v11.currentBorrowIndex(), oldExpected);
        assertEq(v12.currentBorrowIndex(), rayExpected);
        assertNotEq(oldExpected, rayExpected);
        assertEq(LendingPoolV1_1(address(v11)).version(), "1.1");
        assertEq(LendingPoolV1_2(address(v12)).version(), "1.2");
    }

    function test_V1FloorBorrowPreservesHistoricalEventAndLtvBoundary() public {
        _assertLegacyFloorBorrowCompatibility(new LendingPool());
    }

    function test_V1_1FloorBorrowPreservesHistoricalEventAndLtvBoundary() public {
        _assertLegacyFloorBorrowCompatibility(new LendingPoolV1_1());
    }

    function test_BorrowAdmissionFullPrecisionHelperComputesExactFloorQuotient() public {
        BorrowAdmissionMathHarness harness = new BorrowAdmissionMathHarness();

        assertEq(
            harness.scaledToDebtForBorrowAdmission(LEGACY_PRE_BORROW_SCALED_DEBT + 1, LEGACY_OVERFLOW_INDEX),
            LEGACY_POST_BORROW_DISPLAYED_DEBT
        );
    }

    function test_V1BorrowSucceedsWhenPostBorrowAggregateRawProductOverflows() public {
        _assertLegacyBorrowAdmissionOverflowCompatibility(new LendingPool());
    }

    function test_V1_1BorrowSucceedsWhenPostBorrowAggregateRawProductOverflows() public {
        _assertLegacyBorrowAdmissionOverflowCompatibility(new LendingPoolV1_1());
    }

    function test_HistoricalFixtureRepricesOpenIntervalWhileV1_1CheckpointsBoundary() public {
        HistoricalLendingPoolV1InterestFixture historical = new HistoricalLendingPoolV1InterestFixture(0.05e18, 0.2e18);
        LendingPool v11 = _newPool(new LendingPoolV1_1(), 0.05e18, 0.2e18);
        _fundAndApproveActors(v11);
        historical.openPosition(1_000 ether, 500 ether);
        _openPosition(v11, 1_000 ether, 1_000 ether, 500 ether);

        vm.warp(block.timestamp + 90 days);
        uint256 historicalTimestamp = historical.lastBorrowIndexUpdate();
        uint256 v11Boundary = v11.currentBorrowIndex();

        historical.depositLiquidity(9_000 ether);
        vm.prank(provider);
        v11.depositLiquidity(9_000 ether);

        assertEq(historical.lastBorrowIndexUpdate(), historicalTimestamp);
        assertEq(v11.borrowIndex(), v11Boundary);
        assertEq(v11.lastBorrowIndexUpdate(), block.timestamp);
        assertNotEq(historical.currentBorrowIndex(), v11.currentBorrowIndex());
    }

    function test_CurrentBorrowIndexMatchesReferenceWithinDomainAndRejectsUnsupportedOutputs() public {
        uint256[4] memory rates = [uint256(0), WAD / 20, WAD / 5, WAD];
        uint256[6] memory intervals = [uint256(0), 1, 1 days, YEAR, 20 * YEAR, MAX_ELAPSED];

        for (uint256 rateIndex; rateIndex < rates.length; ++rateIndex) {
            LendingPool candidate = _newPool(new LendingPoolV1_2(), rates[rateIndex], 0);
            priceFeed.setUpdatedAt(block.timestamp);
            _fundAndApproveActors(candidate);
            _openPosition(candidate, 1_000 ether, 1_000 ether, 100 ether);
            uint256 start = block.timestamp;

            for (uint256 timeIndex; timeIndex < intervals.length; ++timeIndex) {
                vm.warp(start + intervals[timeIndex]);
                uint256 expected = BorrowIndexMath.accrueIndex(WAD, rates[rateIndex], intervals[timeIndex]);
                uint256 quantum = Math.ceilDiv(expected, WAD);

                if (quantum <= MAX_DEBT_QUANTUM) {
                    assertEq(candidate.currentBorrowIndex(), expected, "reference accrual");
                } else {
                    vm.expectRevert(
                        abi.encodeWithSelector(LendingPoolV1_2.DebtQuantumTooHigh.selector, quantum, MAX_DEBT_QUANTUM)
                    );
                    candidate.currentBorrowIndex();
                }
            }
        }
    }

    function test_CurrentBorrowIndexMatchesReferenceFromSupportedElevatedIndexAndRejectsBoundaryGrowth() public {
        uint256[2] memory indexes = [uint256(2 * WAD), uint256(1e24)];

        for (uint256 i; i < indexes.length; ++i) {
            LendingPool candidate = _newPool(new LendingPoolV1_2(), 0.05e18, 0);
            _fundAndApproveActors(candidate);
            _openPosition(candidate, 1_000 ether, 1_000 ether, 100 ether);
            _setBorrowIndex(candidate, indexes[i]);
            uint256 start = block.timestamp;
            vm.warp(start + YEAR);

            uint256 expected = BorrowIndexMath.accrueIndex(indexes[i], 0.05e18, YEAR);
            uint256 quantum = Math.ceilDiv(expected, WAD);
            if (quantum <= MAX_DEBT_QUANTUM) {
                assertEq(candidate.currentBorrowIndex(), expected);
            } else {
                vm.expectRevert(
                    abi.encodeWithSelector(LendingPoolV1_2.DebtQuantumTooHigh.selector, quantum, MAX_DEBT_QUANTUM)
                );
                candidate.currentBorrowIndex();
            }
        }
    }

    function test_DebtFreeIntervalsFreezeIndexEvenBeyondMaximum() public {
        _setBorrowIndex(pool, 2 * WAD);
        vm.warp(block.timestamp + MAX_ELAPSED + 1);
        assertEq(pool.currentBorrowIndex(), 2 * WAD);
    }

    function test_MaximumBorrowIndexMathOutputIsRejectedAndPlusOneSecondKeepsLibraryBoundary() public {
        LendingPool candidate = _newPool(new LendingPoolV1_2(), WAD, 0);
        priceFeed.setUpdatedAt(block.timestamp);
        _fundAndApproveActors(candidate);
        _openPosition(candidate, 1_000 ether, 1_000 ether, 100 ether);
        uint256 start = block.timestamp;

        vm.warp(start + MAX_ELAPSED);
        assertEq(BorrowIndexMath.accrueIndex(WAD, WAD, MAX_ELAPSED), MAX_BORROW_INDEX_OUTPUT);
        uint256 quantum = Math.ceilDiv(MAX_BORROW_INDEX_OUTPUT, WAD);
        vm.expectRevert(abi.encodeWithSelector(LendingPoolV1_2.DebtQuantumTooHigh.selector, quantum, MAX_DEBT_QUANTUM));
        candidate.currentBorrowIndex();

        vm.warp(start + MAX_ELAPSED + 1);
        vm.expectRevert(
            abi.encodeWithSelector(BorrowIndexMath.AccrualIntervalTooLong.selector, MAX_ELAPSED + 1, MAX_ELAPSED)
        );
        candidate.currentBorrowIndex();
    }

    function test_DebtQuantumExactBoundaryIsSupportedAndNextRawIndexUnitIsRejected() public {
        _setBorrowIndex(pool, MAX_SUPPORTED_INDEX);
        assertEq(pool.currentBorrowIndex(), MAX_SUPPORTED_INDEX);

        _setBorrowIndex(pool, MAX_SUPPORTED_INDEX + 1);
        vm.expectRevert(
            abi.encodeWithSelector(LendingPoolV1_2.DebtQuantumTooHigh.selector, MAX_DEBT_QUANTUM + 1, MAX_DEBT_QUANTUM)
        );
        pool.currentBorrowIndex();
    }

    function test_EighteenDecimalDebtAssetIsSupported() public {
        assertEq(debtToken.decimals(), 18);
        vm.prank(borrower);
        pool.borrow(1 ether);
        assertGe(pool.debtBalanceOf(borrower), 1 ether);
    }

    function test_NonEighteenDecimalDebtAssetIsRejectedBeforeValueMovement() public {
        MockSixDecimalERC20 unsupportedDebt = new MockSixDecimalERC20();
        LendingPoolV1_2 unsupportedImplementation = new LendingPoolV1_2();
        uint256 providerBalanceBefore = unsupportedDebt.balanceOf(provider);

        vm.expectRevert(abi.encodeWithSelector(LendingPoolV1_2.UnsupportedDebtAssetDecimals.selector, uint8(6)));
        _deployLendingPoolProxy(
            unsupportedImplementation,
            LendingPoolProxyConfig({
                priceFeed: address(priceFeed),
                vault: address(vault),
                debtAsset: address(unsupportedDebt),
                maxPriceStaleness: 1 days,
                ltvBps: 7_000,
                liquidationThresholdBps: 8_000,
                liquidationBonusBps: 500,
                baseBorrowRate: 0.05e18,
                borrowRateSlope: 0.2e18,
                initialUpgradeAuthority: address(this)
            })
        );

        assertEq(unsupportedDebt.balanceOf(provider), providerBalanceBefore);
        assertEq(unsupportedDebt.balanceOf(address(unsupportedImplementation)), 0);
    }

    function test_RealMaximumIndexRejectsBorrowRepayAndLiquidationBeforeAnyValueMovement() public {
        vm.prank(borrower);
        pool.borrow(100 ether);
        uint256 scaledBefore = pool.scaledDebtOf(borrower);
        uint256 totalScaledBefore = pool.totalScaledDebt();
        uint256 borrowerDebtTokensBefore = debtToken.balanceOf(borrower);
        uint256 poolDebtTokensBefore = debtToken.balanceOf(address(pool));
        uint256 liquidatorDebtTokensBefore = debtToken.balanceOf(liquidator);
        uint256 liquidatorCollateralBefore = collateralToken.balanceOf(liquidator);
        uint256 borrowerSharesBefore = pool.collateralSharesOf(borrower);
        uint256 timestampBefore = pool.lastBorrowIndexUpdate();

        _setBorrowIndex(pool, MAX_BORROW_INDEX_OUTPUT);
        uint256 quantum = Math.ceilDiv(MAX_BORROW_INDEX_OUTPUT, WAD);
        bytes memory expectedError =
            abi.encodeWithSelector(LendingPoolV1_2.DebtQuantumTooHigh.selector, quantum, MAX_DEBT_QUANTUM);

        vm.prank(borrower);
        vm.expectRevert(expectedError);
        pool.borrow(1 ether);

        vm.prank(borrower);
        vm.expectRevert(expectedError);
        pool.repay(1 ether);

        priceFeed.setAnswer(0.5e8);
        priceFeed.setUpdatedAt(block.timestamp);
        vm.prank(liquidator);
        vm.expectRevert(expectedError);
        pool.liquidate(borrower, 1 ether);

        priceFeed.setAnswer(1);
        vm.prank(liquidator);
        vm.expectRevert(expectedError);
        pool.liquidate(borrower, type(uint256).max);

        assertEq(pool.scaledDebtOf(borrower), scaledBefore);
        assertEq(pool.totalScaledDebt(), totalScaledBefore);
        assertEq(debtToken.balanceOf(borrower), borrowerDebtTokensBefore);
        assertEq(debtToken.balanceOf(address(pool)), poolDebtTokensBefore);
        assertEq(debtToken.balanceOf(liquidator), liquidatorDebtTokensBefore);
        assertEq(collateralToken.balanceOf(liquidator), liquidatorCollateralBefore);
        assertEq(pool.collateralSharesOf(borrower), borrowerSharesBefore);
        assertEq(pool.lastBorrowIndexUpdate(), timestampBefore);
    }

    function test_MaximumSupportedQuantumBoundsBorrowRepayAndLiquidationMismatch() public {
        _setBorrowIndex(pool, MAX_SUPPORTED_INDEX);
        uint256 amount = 100 ether + MAX_DEBT_QUANTUM - 1;
        vm.prank(borrower);
        pool.borrow(amount);

        uint256 firstDebt = pool.debtBalanceOf(borrower);
        assertLe(firstDebt - amount, MAX_DEBT_QUANTUM - 1);

        uint256 secondAmount = 1 ether + 1;
        uint256 debtBeforeSecondBorrow = firstDebt;
        vm.prank(borrower);
        pool.borrow(secondAmount);
        assertLe(pool.debtBalanceOf(borrower) - debtBeforeSecondBorrow - secondAmount, MAX_DEBT_QUANTUM);

        uint256 repayment = 10 ether + MAX_DEBT_QUANTUM - 1;
        uint256 debtBeforeRepay = pool.debtBalanceOf(borrower);
        vm.prank(borrower);
        pool.repay(repayment);
        uint256 debtReduction = debtBeforeRepay - pool.debtBalanceOf(borrower);
        assertLe(repayment - debtReduction, MAX_DEBT_QUANTUM);

        priceFeed.setAnswer(0.011e8);
        priceFeed.setUpdatedAt(block.timestamp);
        uint256 debtBeforeLiquidation = pool.debtBalanceOf(borrower);
        uint256 liquidationPayment = 5 ether + MAX_DEBT_QUANTUM - 1;
        vm.prank(liquidator);
        pool.liquidate(borrower, liquidationPayment);
        uint256 liquidationDebtReduction = debtBeforeLiquidation - pool.debtBalanceOf(borrower);
        assertLe(liquidationPayment - liquidationDebtReduction, MAX_DEBT_QUANTUM);
    }

    function test_BorrowUsesExactCeilMintAndApprovedNewBorrowerBoundAtUnitAndElevatedIndexes() public {
        uint256[3] memory indexes = [uint256(WAD), uint256(2 * WAD), uint256(1e24)];
        uint256 amount = 5 ether + 1;

        for (uint256 i; i < indexes.length; ++i) {
            LendingPool candidate = _newPool(new LendingPoolV1_2(), 0, 0);
            _fundAndApproveActors(candidate);
            _provideLiquidity(candidate, 1_000_000 ether);
            address user = i == 0 ? borrower : i == 1 ? borrowerTwo : borrowerThree;
            _provideCollateral(candidate, user, 10_000 ether);
            _setBorrowIndex(candidate, indexes[i]);

            uint256 balanceBefore = debtToken.balanceOf(user);
            vm.prank(user);
            candidate.borrow(amount);

            uint256 expectedScaled = Math.mulDiv(amount, WAD, indexes[i], Math.Rounding.Ceil);
            uint256 displayed = candidate.debtBalanceOf(user);
            uint256 quantumCeiling = Math.ceilDiv(indexes[i], WAD);

            assertEq(candidate.scaledDebtOf(user), expectedScaled);
            assertGe(displayed, amount);
            assertLe(displayed, amount + quantumCeiling - 1);
            assertGt(expectedScaled, 0);
            assertEq(debtToken.balanceOf(user), balanceBefore + amount);
        }
    }

    function test_MultipleBorrowsUseApprovedExistingAccountIncrementBoundAndExactEventDebt() public {
        _setBorrowIndex(pool, 2 * WAD + 1);
        vm.prank(borrower);
        pool.borrow(10 ether);

        uint256 debtBefore = pool.debtBalanceOf(borrower);
        uint256 scaledBefore = pool.scaledDebtOf(borrower);
        uint256 amount = 3 ether;
        uint256 expectedScaled = Math.mulDiv(amount, WAD, pool.borrowIndex(), Math.Rounding.Ceil);
        uint256 expectedDebt = Math.mulDiv(scaledBefore + expectedScaled, pool.borrowIndex(), WAD);

        vm.expectEmit(true, false, false, true, address(pool));
        emit Borrowed(borrower, amount, expectedDebt);
        vm.prank(borrower);
        pool.borrow(amount);

        uint256 increase = pool.debtBalanceOf(borrower) - debtBefore;
        assertGe(increase, amount);
        assertLe(increase, amount + Math.ceilDiv(pool.borrowIndex(), WAD));
        assertEq(pool.debtBalanceOf(borrower), expectedDebt);
    }

    function test_BorrowersEnteringAtDifferentIndexesDoNotReceivePriorScaledGrowth() public {
        vm.prank(borrower);
        pool.borrow(100 ether);
        uint256 firstScaled = pool.scaledDebtOf(borrower);

        _setBorrowIndex(pool, 2 * WAD + 1);
        uint256 amount = 100 ether;
        vm.prank(borrowerTwo);
        pool.borrow(amount);

        assertEq(pool.scaledDebtOf(borrower), firstScaled);
        assertEq(pool.scaledDebtOf(borrowerTwo), Math.mulDiv(amount, WAD, 2 * WAD + 1, Math.Rounding.Ceil));
        assertGe(pool.debtBalanceOf(borrowerTwo), amount);
        assertLe(pool.debtBalanceOf(borrowerTwo), amount + Math.ceilDiv(2 * WAD + 1, WAD) - 1);
    }

    function test_BorrowRejectsActualNormalizedDebtAboveLtv() public {
        LendingPool candidate = _newPool(new LendingPoolV1_2(), 0, 0, 5_000, 8_000);
        _fundAndApproveActors(candidate);
        _provideLiquidity(candidate, 10 ether);
        _provideCollateral(candidate, borrower, 2 ether);
        _setBorrowIndex(candidate, WAD + 1);

        uint256 amount = 1 ether;
        uint256 requestedPostBorrowDebt = candidate.debtBalanceOf(borrower) + amount;
        uint256 expectedScaled = Math.mulDiv(amount, WAD, candidate.borrowIndex(), Math.Rounding.Ceil);
        uint256 normalizedPostBorrowDebt =
            Math.mulDiv(candidate.scaledDebtOf(borrower) + expectedScaled, candidate.borrowIndex(), WAD);
        uint256 userScaledBefore = candidate.scaledDebtOf(borrower);
        uint256 totalScaledBefore = candidate.totalScaledDebt();
        uint256 borrowerTokensBefore = debtToken.balanceOf(borrower);
        uint256 poolTokensBefore = debtToken.balanceOf(address(candidate));
        uint256 indexBefore = candidate.borrowIndex();
        uint256 timestampBefore = candidate.lastBorrowIndexUpdate();

        assertEq(requestedPostBorrowDebt, candidate.maxBorrowOf(borrower));
        assertGt(normalizedPostBorrowDebt, candidate.maxBorrowOf(borrower));

        vm.prank(borrower);
        vm.expectRevert(LendingPool.BorrowExceedsLimit.selector);
        candidate.borrow(amount);

        assertEq(candidate.scaledDebtOf(borrower), userScaledBefore);
        assertEq(candidate.totalScaledDebt(), totalScaledBefore);
        assertEq(debtToken.balanceOf(borrower), borrowerTokensBefore);
        assertEq(debtToken.balanceOf(address(candidate)), poolTokensBefore);
        assertEq(candidate.borrowIndex(), indexBefore);
        assertEq(candidate.lastBorrowIndexUpdate(), timestampBefore);
    }

    function test_BorrowRejectsActualNormalizedAggregateDebtAboveLiquidity() public {
        LendingPool candidate = _newPool(new LendingPoolV1_2(), 0, 0);
        _fundAndApproveActors(candidate);
        _provideLiquidity(candidate, 1 ether);
        _provideCollateral(candidate, borrower, 2 ether);
        _setBorrowIndex(candidate, WAD + 1);

        uint256 amount = 1 ether;
        uint256 expectedScaled = Math.mulDiv(amount, WAD, candidate.borrowIndex(), Math.Rounding.Ceil);
        uint256 normalizedPostBorrowTotalDebt =
            Math.mulDiv(candidate.totalScaledDebt() + expectedScaled, candidate.borrowIndex(), WAD);
        uint256 userScaledBefore = candidate.scaledDebtOf(borrower);
        uint256 totalScaledBefore = candidate.totalScaledDebt();
        uint256 borrowerTokensBefore = debtToken.balanceOf(borrower);
        uint256 poolTokensBefore = debtToken.balanceOf(address(candidate));
        uint256 indexBefore = candidate.borrowIndex();
        uint256 timestampBefore = candidate.lastBorrowIndexUpdate();

        assertEq(amount, candidate.availableLiquidity());
        assertGt(normalizedPostBorrowTotalDebt, candidate.totalLiquidity());

        vm.prank(borrower);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        candidate.borrow(amount);

        assertEq(candidate.scaledDebtOf(borrower), userScaledBefore);
        assertEq(candidate.totalScaledDebt(), totalScaledBefore);
        assertEq(debtToken.balanceOf(borrower), borrowerTokensBefore);
        assertEq(debtToken.balanceOf(address(candidate)), poolTokensBefore);
        assertEq(candidate.borrowIndex(), indexBefore);
        assertEq(candidate.lastBorrowIndexUpdate(), timestampBefore);
    }

    function test_PartialRepayUsesFloorBurnAndEventMatchesGetter() public {
        _setBorrowIndex(pool, 2 * WAD + 1);
        vm.prank(borrower);
        pool.borrow(100 ether);

        uint256 scaledBefore = pool.scaledDebtOf(borrower);
        uint256 totalScaledBefore = pool.totalScaledDebt();
        uint256 repayment = 3 ether;
        uint256 scaledBurn = Math.mulDiv(repayment, WAD, pool.borrowIndex(), Math.Rounding.Floor);
        uint256 expectedDebt = Math.mulDiv(scaledBefore - scaledBurn, pool.borrowIndex(), WAD);

        vm.expectEmit(true, false, false, true, address(pool));
        emit Repaid(borrower, repayment, expectedDebt);
        vm.prank(borrower);
        pool.repay(repayment);

        assertEq(pool.scaledDebtOf(borrower), scaledBefore - scaledBurn);
        assertEq(pool.totalScaledDebt(), totalScaledBefore - scaledBurn);
        assertEq(pool.debtBalanceOf(borrower), expectedDebt);
    }

    function test_OneRawUnitPartialRepaymentBurnsOneScaledUnitAtWad() public {
        vm.prank(borrower);
        pool.borrow(100 ether);
        uint256 scaledBefore = pool.scaledDebtOf(borrower);

        vm.prank(borrower);
        pool.repay(1);

        assertEq(pool.scaledDebtOf(borrower), scaledBefore - 1);
        assertEq(pool.debtBalanceOf(borrower), 100 ether - 1);
    }

    function test_SubQuantumPartialRepayRevertsWithoutTransferOrPersistentCheckpoint() public {
        _setBorrowIndex(pool, 2 * WAD);
        vm.prank(borrower);
        pool.borrow(100 ether);
        vm.warp(block.timestamp + 1);

        uint256 indexBefore = pool.borrowIndex();
        uint256 timestampBefore = pool.lastBorrowIndexUpdate();
        uint256 userBalanceBefore = debtToken.balanceOf(borrower);
        uint256 poolBalanceBefore = debtToken.balanceOf(address(pool));
        uint256 scaledBefore = pool.scaledDebtOf(borrower);

        vm.prank(borrower);
        vm.expectRevert(LendingPoolV1_2.ZeroScaledAmount.selector);
        pool.repay(1);

        assertEq(pool.borrowIndex(), indexBefore);
        assertEq(pool.lastBorrowIndexUpdate(), timestampBefore);
        assertEq(pool.scaledDebtOf(borrower), scaledBefore);
        assertEq(debtToken.balanceOf(borrower), userBalanceBefore);
        assertEq(debtToken.balanceOf(address(pool)), poolBalanceBefore);
    }

    function test_FailedNormalizedBorrowRollsBackEarlierCheckpoint() public {
        vm.prank(borrower);
        pool.borrow(100 ether);
        vm.warp(block.timestamp + 30 days);

        uint256 indexBefore = pool.borrowIndex();
        uint256 timestampBefore = pool.lastBorrowIndexUpdate();
        uint256 scaledBefore = pool.scaledDebtOf(borrower);

        vm.prank(borrower);
        vm.expectRevert(LendingPool.BorrowExceedsLimit.selector);
        pool.borrow(10_000 ether);

        assertEq(pool.borrowIndex(), indexBefore);
        assertEq(pool.lastBorrowIndexUpdate(), timestampBefore);
        assertEq(pool.scaledDebtOf(borrower), scaledBefore);
    }

    function test_FullAndOverpaymentClearAllScaledDebtWithoutDust() public {
        _setBorrowIndex(pool, 2 * WAD + 1);
        vm.prank(borrower);
        pool.borrow(100 ether);
        uint256 displayedDebt = pool.debtBalanceOf(borrower);
        uint256 totalScaledBefore = pool.totalScaledDebt();
        uint256 userScaledBefore = pool.scaledDebtOf(borrower);
        uint256 userBalanceBefore = debtToken.balanceOf(borrower);

        vm.expectEmit(true, false, false, true, address(pool));
        emit Repaid(borrower, displayedDebt, 0);
        vm.prank(borrower);
        pool.repay(type(uint256).max);

        assertEq(pool.scaledDebtOf(borrower), 0);
        assertEq(pool.debtBalanceOf(borrower), 0);
        assertEq(pool.totalScaledDebt(), totalScaledBefore - userScaledBefore);
        assertEq(debtToken.balanceOf(borrower), userBalanceBefore - displayedDebt);
    }

    function test_PartialLiquidationUsesFloorScaledBurn() public {
        _openLiquidatablePositionAtTwoWad();
        uint256 repayment = 10 ether + 1;
        uint256 scaledBefore = pool.scaledDebtOf(borrower);
        uint256 scaledBurn = Math.mulDiv(repayment, WAD, pool.borrowIndex(), Math.Rounding.Floor);

        vm.prank(liquidator);
        pool.liquidate(borrower, repayment);

        assertEq(pool.scaledDebtOf(borrower), scaledBefore - scaledBurn);
        assertEq(pool.debtBalanceOf(borrower), Math.mulDiv(scaledBefore - scaledBurn, pool.borrowIndex(), WAD));
    }

    function test_ZeroScaledLiquidationRevertsWithoutPaymentSeizureOrCheckpoint() public {
        _openLiquidatablePositionAtTwoWad();
        vm.warp(block.timestamp + 1);
        priceFeed.setUpdatedAt(block.timestamp);

        uint256 indexBefore = pool.borrowIndex();
        uint256 timestampBefore = pool.lastBorrowIndexUpdate();
        uint256 liquidatorDebtBefore = debtToken.balanceOf(liquidator);
        uint256 liquidatorCollateralBefore = collateralToken.balanceOf(liquidator);
        uint256 borrowerSharesBefore = pool.collateralSharesOf(borrower);

        vm.prank(liquidator);
        vm.expectRevert(LendingPoolV1_2.ZeroScaledAmount.selector);
        pool.liquidate(borrower, 1);

        assertEq(pool.borrowIndex(), indexBefore);
        assertEq(pool.lastBorrowIndexUpdate(), timestampBefore);
        assertEq(debtToken.balanceOf(liquidator), liquidatorDebtBefore);
        assertEq(collateralToken.balanceOf(liquidator), liquidatorCollateralBefore);
        assertEq(pool.collateralSharesOf(borrower), borrowerSharesBefore);
    }

    function test_FullDisplayedDebtLiquidationClearsAllScaledDebt() public {
        _openLiquidatablePositionAtTwoWad();
        uint256 debt = pool.debtBalanceOf(borrower);
        uint256 totalScaledBefore = pool.totalScaledDebt();
        uint256 borrowerScaledBefore = pool.scaledDebtOf(borrower);

        vm.prank(liquidator);
        pool.liquidate(borrower, debt + 1 ether);

        assertEq(pool.scaledDebtOf(borrower), 0);
        assertEq(pool.debtBalanceOf(borrower), 0);
        assertEq(pool.totalScaledDebt(), totalScaledBefore - borrowerScaledBefore);
    }

    function test_CollateralLimitedLiquidationKeepsDebtAndScaledAccountingConsistent() public {
        _setBorrowIndex(pool, 2 * WAD);
        vm.prank(borrower);
        pool.borrow(100 ether);
        priceFeed.setAnswer(0.001e8);
        priceFeed.setUpdatedAt(block.timestamp);

        uint256 debtBefore = pool.debtBalanceOf(borrower);
        uint256 scaledBefore = pool.scaledDebtOf(borrower);
        uint256 collateralValue = pool.getCollateralAssets(borrower) * 0.001e18 / WAD;
        uint256 actualRepay = collateralValue * BPS / (BPS + pool.liquidationBonusBps());
        uint256 scaledBurn = Math.mulDiv(actualRepay, WAD, pool.borrowIndex(), Math.Rounding.Floor);

        vm.prank(liquidator);
        pool.liquidate(borrower, debtBefore);

        assertEq(pool.scaledDebtOf(borrower), scaledBefore - scaledBurn);
        assertEq(pool.debtBalanceOf(borrower), Math.mulDiv(scaledBefore - scaledBurn, pool.borrowIndex(), WAD));
        assertEq(pool.collateralSharesOf(borrower), 0);
    }

    function test_FullWidthDebtAndUtilizationConversionsSucceedWhenProductsOverflow() public {
        uint256 scaled = type(uint256).max / 2;
        _setBorrowIndex(pool, 2 * WAD);
        stdstore.target(address(pool)).sig("scaledDebtOf(address)").with_key(borrower).checked_write(scaled);
        stdstore.target(address(pool)).sig("totalScaledDebt()").checked_write(scaled);
        stdstore.target(address(pool)).sig("totalLiquidity()").checked_write(type(uint256).max);

        assertEq(pool.debtBalanceOf(borrower), type(uint256).max - 1);
        assertEq(pool.totalDebt(), type(uint256).max - 1);
        assertEq(pool.utilizationRate(), WAD - 1);

        _setBorrowIndex(pool, WAD);
        assertEq(pool.utilizationRate(), WAD / 2 - 1);
    }

    function test_Task6ACheckpointContinuityAndImplementationCustodyFree() public {
        vm.prank(borrower);
        pool.borrow(100 ether);
        vm.warp(block.timestamp + 30 days);
        uint256 boundary = pool.currentBorrowIndex();

        debtToken.mint(provider, 1_000 ether);
        vm.prank(provider);
        pool.depositLiquidity(1_000 ether);

        assertEq(pool.borrowIndex(), boundary);
        assertEq(pool.currentBorrowIndex(), boundary);
        assertEq(debtToken.balanceOf(address(implementation)), 0);
        assertEq(collateralToken.balanceOf(address(implementation)), 0);
        assertEq(vault.balanceOf(address(implementation)), 0);
    }

    function _openLiquidatablePositionAtTwoWad() internal {
        _setBorrowIndex(pool, 2 * WAD);
        vm.prank(borrower);
        pool.borrow(100 ether);
        priceFeed.setAnswer(0.011e8);
        priceFeed.setUpdatedAt(block.timestamp);
        assertTrue(pool.isLiquidatable(borrower));
    }

    function _newV12Pool(uint256 baseRate, uint256 slope)
        internal
        returns (LendingPoolV1_2 candidate, LendingPoolV1_2 candidateImplementation)
    {
        candidateImplementation = new LendingPoolV1_2();
        candidate = LendingPoolV1_2(address(_newPool(candidateImplementation, baseRate, slope)));
    }

    function _newPool(LendingPool candidateImplementation, uint256 baseRate, uint256 slope)
        internal
        returns (LendingPool candidate)
    {
        return _newPool(candidateImplementation, baseRate, slope, 7_000, 8_000);
    }

    function _newPool(
        LendingPool candidateImplementation,
        uint256 baseRate,
        uint256 slope,
        uint256 ltv,
        uint256 liquidationThreshold
    ) internal returns (LendingPool candidate) {
        candidate = _deployLendingPoolProxy(
            candidateImplementation,
            LendingPoolProxyConfig({
                priceFeed: address(priceFeed),
                vault: address(vault),
                debtAsset: address(debtToken),
                maxPriceStaleness: 200 * YEAR,
                ltvBps: ltv,
                liquidationThresholdBps: liquidationThreshold,
                liquidationBonusBps: 500,
                baseBorrowRate: baseRate,
                borrowRateSlope: slope,
                initialUpgradeAuthority: address(this)
            })
        );
    }

    function _fundAndApproveActors(LendingPool candidate) internal {
        address[5] memory actors = [borrower, borrowerTwo, borrowerThree, provider, liquidator];
        for (uint256 i; i < actors.length; ++i) {
            collateralToken.mint(actors[i], 100_000_000 ether);
            debtToken.mint(actors[i], 100_000_000 ether);
            vm.startPrank(actors[i]);
            collateralToken.approve(address(candidate), type(uint256).max);
            debtToken.approve(address(candidate), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _provideLiquidity(LendingPool candidate, uint256 amount) internal {
        vm.prank(provider);
        candidate.depositLiquidity(amount);
    }

    function _provideCollateral(LendingPool candidate, address user, uint256 amount) internal {
        vm.prank(user);
        candidate.depositCollateral(amount);
    }

    function _openPosition(LendingPool candidate, uint256 liquidity, uint256 collateral, uint256 amount) internal {
        _provideLiquidity(candidate, liquidity);
        _provideCollateral(candidate, borrower, collateral);
        vm.prank(borrower);
        candidate.borrow(amount);
    }

    function _assertLegacyFloorBorrowCompatibility(LendingPool candidateImplementation) internal {
        uint256 collateral = 28 ether + 10;
        uint256 amount = 4 ether;
        uint256 elevatedIndex = 2 * WAD + 1;

        LendingPool accepted = _newPool(candidateImplementation, 0, 0, 5_000, 8_000);
        _fundAndApproveActors(accepted);
        _provideLiquidity(accepted, 100 ether);
        _provideCollateral(accepted, borrower, collateral);
        vm.prank(borrower);
        accepted.borrow(5 ether);
        _setBorrowIndex(accepted, elevatedIndex);

        uint256 displayedDebtBefore = accepted.debtBalanceOf(borrower);
        uint256 requestedPostBorrowDebt = displayedDebtBefore + amount;
        uint256 expectedScaledAmount = Math.mulDiv(amount, WAD, elevatedIndex, Math.Rounding.Floor);
        uint256 normalizedPostBorrowDebt = Math.mulDiv(
            accepted.scaledDebtOf(borrower) + expectedScaledAmount, elevatedIndex, WAD, Math.Rounding.Floor
        );

        assertEq(requestedPostBorrowDebt, accepted.maxBorrowOf(borrower));
        assertLt(normalizedPostBorrowDebt, requestedPostBorrowDebt);

        vm.expectEmit(true, false, false, true, address(accepted));
        emit Borrowed(borrower, amount, requestedPostBorrowDebt);
        vm.prank(borrower);
        accepted.borrow(amount);

        assertEq(accepted.debtBalanceOf(borrower), normalizedPostBorrowDebt);
        assertEq(accepted.scaledDebtOf(borrower), 5 ether + expectedScaledAmount);

        LendingPool rejected = _newPool(candidateImplementation, 0, 0, 5_000, 8_000);
        _fundAndApproveActors(rejected);
        _provideLiquidity(rejected, 100 ether);
        _provideCollateral(rejected, borrower, collateral);
        vm.prank(borrower);
        rejected.borrow(5 ether);
        _setBorrowIndex(rejected, elevatedIndex);

        uint256 rejectedUserScaledBefore = rejected.scaledDebtOf(borrower);
        uint256 rejectedTotalScaledBefore = rejected.totalScaledDebt();
        uint256 rejectedBorrowerTokensBefore = debtToken.balanceOf(borrower);
        uint256 rejectedPoolTokensBefore = debtToken.balanceOf(address(rejected));

        vm.prank(borrower);
        vm.expectRevert(LendingPool.BorrowExceedsLimit.selector);
        rejected.borrow(amount + 1);

        assertEq(rejected.scaledDebtOf(borrower), rejectedUserScaledBefore);
        assertEq(rejected.totalScaledDebt(), rejectedTotalScaledBefore);
        assertEq(debtToken.balanceOf(borrower), rejectedBorrowerTokensBefore);
        assertEq(debtToken.balanceOf(address(rejected)), rejectedPoolTokensBefore);
    }

    function _assertLegacyBorrowAdmissionOverflowCompatibility(LendingPool candidateImplementation) internal {
        uint256 firstScaledDebt = LEGACY_PRE_BORROW_SCALED_DEBT / 2;
        uint256 secondScaledDebt = LEGACY_PRE_BORROW_SCALED_DEBT - firstScaledDebt;
        uint256 firstCollateral = Math.mulDiv(firstScaledDebt, BPS, 7_000, Math.Rounding.Ceil);
        uint256 secondCollateral = Math.mulDiv(secondScaledDebt, BPS, 7_000, Math.Rounding.Ceil);
        uint256 liquidity = LEGACY_PRE_BORROW_DISPLAYED_DEBT + 3;

        LendingPool candidate = _newPool(candidateImplementation, WAD, 0);
        _fundAndApproveActors(candidate);
        debtToken.mint(provider, liquidity);
        collateralToken.mint(borrower, firstCollateral);
        collateralToken.mint(borrowerTwo, secondCollateral);

        _provideLiquidity(candidate, liquidity);
        _provideCollateral(candidate, borrower, firstCollateral);
        _provideCollateral(candidate, borrowerTwo, secondCollateral);
        _provideCollateral(candidate, borrowerThree, 10);

        vm.prank(borrower);
        candidate.borrow(firstScaledDebt);
        vm.prank(borrowerTwo);
        candidate.borrow(secondScaledDebt);

        assertEq(candidate.borrowIndex(), WAD);
        assertEq(candidate.totalScaledDebt(), LEGACY_PRE_BORROW_SCALED_DEBT);
        assertLe(LEGACY_PRE_BORROW_SCALED_DEBT, type(uint256).max / LEGACY_OVERFLOW_INDEX);
        assertGt(LEGACY_PRE_BORROW_SCALED_DEBT + 1, type(uint256).max / LEGACY_OVERFLOW_INDEX);
        assertEq(LEGACY_PRE_BORROW_SCALED_DEBT * LEGACY_OVERFLOW_INDEX / WAD, LEGACY_PRE_BORROW_DISPLAYED_DEBT);
        assertEq(
            Math.mulDiv(LEGACY_PRE_BORROW_SCALED_DEBT + 1, LEGACY_OVERFLOW_INDEX, WAD, Math.Rounding.Floor),
            LEGACY_POST_BORROW_DISPLAYED_DEBT
        );

        vm.warp(block.timestamp + YEAR);

        assertEq(candidate.currentBorrowIndex(), LEGACY_OVERFLOW_INDEX);
        assertEq(candidate.availableLiquidity(), 3);
        assertEq(candidate.maxBorrowOf(borrowerThree), 7);

        uint256 borrowerTokensBefore = debtToken.balanceOf(borrowerThree);
        uint256 poolTokensBefore = debtToken.balanceOf(address(candidate));

        vm.expectEmit(false, false, false, true, address(candidate));
        emit BorrowIndexUpdated(LEGACY_OVERFLOW_INDEX);
        vm.expectEmit(true, false, false, true, address(candidate));
        emit Borrowed(borrowerThree, 3, 3);
        vm.prank(borrowerThree);
        candidate.borrow(3);

        assertEq(candidate.borrowIndex(), LEGACY_OVERFLOW_INDEX);
        assertEq(candidate.lastBorrowIndexUpdate(), block.timestamp);
        assertEq(candidate.scaledDebtOf(borrowerThree), 1);
        assertEq(candidate.totalScaledDebt(), LEGACY_PRE_BORROW_SCALED_DEBT + 1);
        assertEq(candidate.totalLiquidity(), liquidity);
        assertEq(debtToken.balanceOf(borrowerThree), borrowerTokensBefore + 3);
        assertEq(debtToken.balanceOf(address(candidate)), poolTokensBefore - 3);
    }

    function _setBorrowIndex(LendingPool candidate, uint256 index) internal {
        stdstore.target(address(candidate)).sig("borrowIndex()").checked_write(index);
        stdstore.target(address(candidate)).sig("lastBorrowIndexUpdate()").checked_write(block.timestamp);
    }
}
