// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, stdError} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {LendingPoolProxyFixture} from "../helpers/LendingPoolProxyFixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

import {LendingPool} from "../../src/core/lending/LendingPool.sol";
import {LendingPoolV1_1} from "../../src/core/lending/LendingPoolV1_1.sol";
import {LendingPoolV1_2} from "../../src/core/lending/LendingPoolV1_2.sol";
import {CollateralVault} from "../../src/core/vault/CollateralVault.sol";
import {BorrowIndexMath} from "../../src/lib/BorrowIndexMath.sol";

contract MigrationSixDecimalERC20 is MockERC20 {
    constructor() MockERC20("Six Decimal Debt", "SIX") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MigrationAccountingProbeERC20 is MockERC20 {
    address internal accountingTarget;

    error AccountingWasActiveDuringMigration();
    error UnexpectedAccountingProbeError(bytes returnData);

    constructor() MockERC20("Accounting Probe Debt", "PROBE") {}

    function setAccountingTarget(address target) external {
        accountingTarget = target;
    }

    function decimals() public view override returns (uint8) {
        if (accountingTarget != address(0)) {
            (bool success, bytes memory returnData) =
                accountingTarget.staticcall(abi.encodeCall(LendingPool.currentBorrowIndex, ()));
            if (success) revert AccountingWasActiveDuringMigration();
            // The length check makes truncation to the four-byte error selector intentional and safe.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (returnData.length < 4 || bytes4(returnData) != LendingPoolV1_2.V1_2AccountingInactive.selector) {
                revert UnexpectedAccountingProbeError(returnData);
            }
        }
        return 18;
    }
}

contract LendingPoolV1_2MigrationHarness is LendingPoolV1_2 {
    function initializedVersion() external view returns (uint64) {
        return _getInitializedVersion();
    }

    function initializableStorageSlot() external pure returns (bytes32) {
        return _initializableStorageSlot();
    }
}

contract LendingPoolV1_2MigrationIntegrationTest is Test, LendingPoolProxyFixture {
    struct RepresentativeSnapshot {
        uint256 storedIndex;
        uint256 lastIndexUpdate;
        uint256 currentIndex;
        uint256 debtOne;
        uint256 debtTwo;
        uint256 totalDebt;
        uint256 scaledDebtOne;
        uint256 scaledDebtTwo;
        uint256 totalScaledDebt;
        uint256 collateralSharesOne;
        uint256 collateralSharesTwo;
        uint256 totalCollateralShares;
        uint256 totalLiquidity;
        uint256 providerLiquidity;
        address upgradeAuthority;
        address pendingUpgradeAuthority;
        bytes32 unchangedProtocolState;
        bytes32 custodyState;
    }

    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant MAX_DEBT_QUANTUM = 1_000_000;
    uint256 internal constant MAX_SUPPORTED_INDEX = MAX_DEBT_QUANTUM * WAD;

    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 internal constant UPGRADE_AUTHORITY_STORAGE =
        0x8000ce11f38414f298b74975bfaea500fcdbebb431834e96f66ac2883c9bb800;

    MockERC20 internal collateralToken;
    MockERC20 internal debtToken;
    CollateralVault internal vault;
    MockV3Aggregator internal priceFeed;
    LendingPoolV1_2MigrationHarness internal v12Implementation;

    address internal borrowerOne = makeAddr("borrowerOne");
    address internal borrowerTwo = makeAddr("borrowerTwo");
    address internal provider = makeAddr("provider");
    address internal liquidator = makeAddr("liquidator");
    address internal pendingAuthority = makeAddr("pendingAuthority");
    address internal unauthorized = makeAddr("unauthorized");

    event V1_2Activated(
        uint256 previousBorrowIndex,
        uint256 settledBorrowIndex,
        uint256 elapsedLegacySeconds,
        uint256 activationTimestamp
    );

    function setUp() public {
        collateralToken = new MockERC20("Collateral", "COL");
        debtToken = new MockERC20("Debt", "DEBT");
        vault = new CollateralVault("Vault Share", "VSH", collateralToken);
        priceFeed = new MockV3Aggregator(8, 1e8, block.timestamp);
        v12Implementation = new LendingPoolV1_2MigrationHarness();
    }

    function test_AtomicallyMigratesRepresentativeV1StateWithExactContinuity() public {
        _assertRepresentativeMigration(new LendingPool());
    }

    function test_AtomicallyMigratesRepresentativeV1_1StateWithExactContinuity() public {
        _assertRepresentativeMigration(new LendingPoolV1_1());
    }

    function test_V1_2PinsEstablishedInitializableStorageSlot() public view {
        assertEq(v12Implementation.initializableStorageSlot(), INITIALIZABLE_STORAGE);
    }

    function test_ZeroElapsedMigrationSettlesStoredIndexExactly() public {
        LendingPool legacy = _deployLegacy(new LendingPool());
        _fundAndApprove(legacy);
        _seedDebt(legacy);

        uint256 previousIndex = legacy.borrowIndex();
        vm.expectEmit(false, false, false, true, address(legacy));
        emit V1_2Activated(previousIndex, previousIndex, 0, block.timestamp);
        _atomicMigrate(legacy, v12Implementation);

        assertEq(legacy.borrowIndex(), previousIndex);
        assertEq(legacy.lastBorrowIndexUpdate(), block.timestamp);
    }

    function test_ZeroDebtElapsedIntervalKeepsStoredIndex() public {
        LendingPool legacy = _deployLegacy(new LendingPool());
        uint256 previousIndex = legacy.borrowIndex();
        vm.warp(block.timestamp + 400 days);

        vm.expectEmit(false, false, false, true, address(legacy));
        emit V1_2Activated(previousIndex, previousIndex, 400 days, block.timestamp);
        _atomicMigrate(legacy, v12Implementation);

        assertEq(legacy.borrowIndex(), previousIndex);
    }

    function test_ZeroUtilizationLegacySettlementUsesBaseRate() public {
        LendingPool legacy = _deployLegacy(new LendingPool());
        vm.store(address(legacy), bytes32(uint256(14)), bytes32(uint256(100 ether)));
        uint256 previousIndex = legacy.borrowIndex();
        uint256 start = legacy.lastBorrowIndexUpdate();
        vm.warp(start + 30 days);
        uint256 expected = _legacyAccrue(previousIndex, legacy.baseBorrowRate(), 30 days);

        _atomicMigrate(legacy, v12Implementation);

        assertEq(legacy.borrowIndex(), expected);
        assertEq(LendingPoolV1_2(address(legacy)).utilizationRate(), 0);
    }

    function test_ZeroIndexRevertsAtomicUpgradeAndAllState() public {
        _assertLowIndexMigrationRejected(0);
    }

    function test_IndexOneBelowWadRevertsAtomicUpgradeAndAllState() public {
        _assertLowIndexMigrationRejected(WAD - 1);
    }

    function test_MinimumSupportedIndexWadIsAccepted() public {
        LendingPool legacy = _deployLegacy(new LendingPool());
        vm.store(address(legacy), bytes32(uint256(8)), bytes32(WAD));
        vm.store(address(legacy), bytes32(uint256(9)), bytes32(block.timestamp));

        _atomicMigrate(legacy, v12Implementation);

        assertEq(legacy.borrowIndex(), WAD);
        assertEq(LendingPoolV1_2MigrationHarness(address(legacy)).initializedVersion(), 2);
    }

    function test_MaximumSupportedIndexIsAccepted() public {
        LendingPool legacy = _deployLegacy(new LendingPool());
        vm.store(address(legacy), bytes32(uint256(8)), bytes32(MAX_SUPPORTED_INDEX));
        vm.store(address(legacy), bytes32(uint256(9)), bytes32(block.timestamp));

        _atomicMigrate(legacy, v12Implementation);

        assertEq(legacy.borrowIndex(), MAX_SUPPORTED_INDEX);
        assertEq(LendingPoolV1_2MigrationHarness(address(legacy)).initializedVersion(), 2);
    }

    function test_FirstUnsupportedDebtQuantumRevertsAtomicUpgradeAndAllState() public {
        LendingPool legacy = _deployLegacy(new LendingPool());
        _fundAndApprove(legacy);
        _seedDebt(legacy);
        vm.store(address(legacy), bytes32(uint256(8)), bytes32(MAX_SUPPORTED_INDEX + 1));
        vm.store(address(legacy), bytes32(uint256(9)), bytes32(block.timestamp));
        bytes32 beforeState = _stateDigest(legacy);

        vm.expectRevert(
            abi.encodeWithSelector(LendingPoolV1_2.DebtQuantumTooHigh.selector, MAX_DEBT_QUANTUM + 1, MAX_DEBT_QUANTUM)
        );
        _atomicMigrate(legacy, v12Implementation);

        assertEq(_stateDigest(legacy), beforeState);
    }

    function test_UnsupportedDecimalsRevertAtomicUpgradeAndAllState() public {
        debtToken = new MigrationSixDecimalERC20();
        LendingPool legacy = _deployLegacy(new LendingPool());
        _fundAndApprove(legacy);
        _seedDebt(legacy);
        vm.warp(block.timestamp + 1 days);
        bytes32 beforeState = _stateDigest(legacy);

        vm.expectRevert(abi.encodeWithSelector(LendingPoolV1_2.UnsupportedDebtAssetDecimals.selector, uint8(6)));
        _atomicMigrate(legacy, v12Implementation);

        assertEq(_stateDigest(legacy), beforeState);
    }

    function test_AccountingRemainsInactiveThroughoutMigrationValidation() public {
        MigrationAccountingProbeERC20 probeToken = new MigrationAccountingProbeERC20();
        debtToken = probeToken;
        LendingPool legacy = _deployLegacy(new LendingPool());
        probeToken.setAccountingTarget(address(legacy));

        _atomicMigrate(legacy, v12Implementation);

        LendingPoolV1_2 migrated = LendingPoolV1_2(address(legacy));
        assertEq(LendingPoolV1_2MigrationHarness(address(migrated)).initializedVersion(), 2);
        assertEq(migrated.currentBorrowIndex(), WAD);
    }

    function test_BaseRateAboveWadRevertsAtomicUpgradeAndAllState() public {
        _assertRateMigrationRejected(WAD + 1, 0);
    }

    function test_SlopeAboveRemainingRateDomainRevertsAtomicUpgradeAndAllState() public {
        _assertRateMigrationRejected(0.4e18, 0.6e18 + 1);
    }

    function test_ExactMaximumInterestRateDomainIsAccepted() public {
        LendingPool legacy = _deployLegacy(new LendingPool());
        vm.store(address(legacy), bytes32(uint256(12)), bytes32(uint256(0.4e18)));
        vm.store(address(legacy), bytes32(uint256(13)), bytes32(uint256(0.6e18)));

        _atomicMigrate(legacy, v12Implementation);

        assertEq(legacy.baseBorrowRate() + legacy.borrowRateSlope(), WAD);
        assertEq(LendingPoolV1_2MigrationHarness(address(legacy)).initializedVersion(), 2);
    }

    function test_OrdinaryInterestRateDomainIsAccepted() public {
        LendingPool legacy = _deployLegacy(new LendingPool());

        _atomicMigrate(legacy, v12Implementation);

        assertEq(legacy.baseBorrowRate(), 0.05e18);
        assertEq(legacy.borrowRateSlope(), 0.2e18);
        assertEq(LendingPoolV1_2MigrationHarness(address(legacy)).initializedVersion(), 2);
    }

    function test_ZeroLiquiditySkipsOverflowingStoredDebtProductAndMigratesExactly() public {
        LendingPool legacy = _deployLegacy(new LendingPool());
        vm.store(address(legacy), bytes32(uint256(14)), bytes32(type(uint256).max));
        uint256 previousTimestamp = legacy.lastBorrowIndexUpdate();
        vm.warp(previousTimestamp + 1 days);
        uint256 expectedLegacyIndex = legacy.currentBorrowIndex();
        bytes32 unchangedProtocolState = _unchangedProtocolStateDigest(legacy);
        bytes32 custodyState = _custodyDigest(legacy);

        _atomicMigrate(legacy, v12Implementation);

        LendingPoolV1_2 migrated = LendingPoolV1_2(address(legacy));
        assertEq(migrated.borrowIndex(), expectedLegacyIndex);
        assertEq(migrated.lastBorrowIndexUpdate(), block.timestamp);
        assertEq(LendingPoolV1_2MigrationHarness(address(migrated)).initializedVersion(), 2);
        assertEq(_unchangedProtocolStateDigest(migrated), unchangedProtocolState);
        assertEq(_custodyDigest(migrated), custodyState);

        uint256 migrationTimestamp = block.timestamp;
        uint256 postMigrationRate = migrated.currentBorrowRate();
        vm.warp(migrationTimestamp + 1 days);
        assertEq(
            migrated.currentBorrowIndex(), BorrowIndexMath.accrueIndex(expectedLegacyIndex, postMigrationRate, 1 days)
        );
        assertEq(migrated.lastBorrowIndexUpdate(), migrationTimestamp);
    }

    function test_GenuineLegacyStoredDebtOverflowRevertsGetterAndAtomicMigrationWithFullRollback() public {
        LendingPool legacy = _deployLegacy(new LendingPoolV1_1());
        vm.store(address(legacy), bytes32(uint256(11)), bytes32(uint256(1)));
        vm.store(address(legacy), bytes32(uint256(14)), bytes32(type(uint256).max));
        vm.warp(block.timestamp + 1);

        vm.expectRevert(stdError.arithmeticError);
        legacy.currentBorrowIndex();
        bytes32 beforeState = _stateDigest(legacy);

        vm.expectRevert(stdError.arithmeticError);
        _atomicMigrate(legacy, v12Implementation);

        assertEq(_stateDigest(legacy), beforeState);
        assertEq(uint256(vm.load(address(legacy), INITIALIZABLE_STORAGE)) & type(uint64).max, 1);
    }

    function test_UnauthorizedAtomicUpgradeRevertsAndAllStateRemainsUnchanged() public {
        LendingPool legacy = _deployLegacy(new LendingPoolV1_1());
        _fundAndApprove(legacy);
        _seedDebt(legacy);
        bytes32 beforeState = _stateDigest(legacy);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.UnauthorizedUpgradeAuthority.selector, unauthorized));
        _atomicMigrate(legacy, v12Implementation);

        assertEq(_stateDigest(legacy), beforeState);
    }

    function test_PendingAuthorityCannotMigrateBeforeAcceptanceAndStateRemainsUnchanged() public {
        LendingPool legacy = _deployLegacy(new LendingPoolV1_1());
        legacy.proposeUpgradeAuthority(pendingAuthority);
        legacy.upgradeToAndCall(address(v12Implementation), "");
        bytes32 beforeState = _stateDigest(legacy);

        vm.prank(pendingAuthority);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.UnauthorizedUpgradeAuthority.selector, pendingAuthority));
        LendingPoolV1_2(address(legacy)).migrateToV1_2();

        assertEq(_stateDigest(legacy), beforeState);
        assertEq(uint256(vm.load(address(legacy), INITIALIZABLE_STORAGE)) & type(uint64).max, 1);
        assertEq(legacy.upgradeAuthority(), address(this));
        assertEq(legacy.pendingUpgradeAuthority(), pendingAuthority);
    }

    function test_RepeatedInitializationDuringAtomicUpgradeRollsBackNewImplementation() public {
        LendingPool legacy = _deployLegacy(new LendingPool());
        _atomicMigrate(legacy, v12Implementation);
        LendingPoolV1_2MigrationHarness replacement = new LendingPoolV1_2MigrationHarness();
        bytes32 beforeState = _stateDigest(legacy);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _atomicMigrate(legacy, replacement);

        assertEq(_stateDigest(legacy), beforeState);
        assertEq(_implementationOf(legacy), address(v12Implementation));
    }

    function test_SecondMigrationCallFailsAndDirectImplementationCallFails() public {
        LendingPool legacy = _deployLegacy(new LendingPool());
        _atomicMigrate(legacy, v12Implementation);
        bytes32 beforeState = _stateDigest(legacy);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        LendingPoolV1_2(address(legacy)).migrateToV1_2();
        assertEq(_stateDigest(legacy), beforeState);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v12Implementation.migrateToV1_2();
        assertEq(debtToken.balanceOf(address(v12Implementation)), 0);
        assertEq(collateralToken.balanceOf(address(v12Implementation)), 0);
        assertEq(vault.balanceOf(address(v12Implementation)), 0);
    }

    function test_UnsafeEmptyDataInstallFailsClosedThenAuthorizedMigrationRecovers() public {
        LendingPool legacy = _deployLegacy(new LendingPoolV1_1());
        _fundAndApprove(legacy);
        _seedRepresentativeState(legacy);
        vm.warp(block.timestamp + 45 days);
        uint256 expectedLegacyIndex = _legacyCurrentIndex(legacy);

        legacy.upgradeToAndCall(address(v12Implementation), "");
        LendingPoolV1_2 installed = LendingPoolV1_2(address(legacy));
        assertEq(_implementationOf(legacy), address(v12Implementation));
        assertEq(LendingPoolV1_2MigrationHarness(address(legacy)).initializedVersion(), 1);
        _assertInactiveAccounting(installed);

        uint256 collateralBefore = installed.collateralSharesOf(liquidator);
        vm.prank(liquidator);
        installed.depositCollateral(1 ether);
        assertGt(installed.collateralSharesOf(liquidator), collateralBefore);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.UnauthorizedUpgradeAuthority.selector, unauthorized));
        installed.migrateToV1_2();
        _assertInactiveAccounting(installed);

        installed.migrateToV1_2();
        assertEq(installed.borrowIndex(), expectedLegacyIndex);
        assertEq(LendingPoolV1_2MigrationHarness(address(installed)).initializedVersion(), 2);
        assertEq(installed.currentBorrowIndex(), expectedLegacyIndex);
    }

    function test_FailedRecoveryMigrationLeavesUnsafeInstallInactiveAndUnchanged() public {
        debtToken = new MigrationSixDecimalERC20();
        LendingPool legacy = _deployLegacy(new LendingPool());
        legacy.upgradeToAndCall(address(v12Implementation), "");
        LendingPoolV1_2 installed = LendingPoolV1_2(address(legacy));
        bytes32 beforeState = _stateDigest(legacy);

        vm.expectRevert(abi.encodeWithSelector(LendingPoolV1_2.UnsupportedDebtAssetDecimals.selector, uint8(6)));
        installed.migrateToV1_2();

        assertEq(_stateDigest(legacy), beforeState);
        assertEq(_implementationOf(legacy), address(v12Implementation));
        assertEq(LendingPoolV1_2MigrationHarness(address(legacy)).initializedVersion(), 1);
        _assertInactiveAccounting(installed);
    }

    function test_FreshV1_2ProxyStartsInactiveAndOnlyAuthorityCanActivate() public {
        LendingPool freshBase = _deployLegacy(v12Implementation);
        LendingPoolV1_2 fresh = LendingPoolV1_2(address(freshBase));
        assertEq(LendingPoolV1_2MigrationHarness(address(fresh)).initializedVersion(), 1);
        _assertInactiveAccounting(fresh);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.UnauthorizedUpgradeAuthority.selector, unauthorized));
        fresh.migrateToV1_2();
        _assertInactiveAccounting(fresh);

        fresh.migrateToV1_2();
        assertEq(LendingPoolV1_2MigrationHarness(address(fresh)).initializedVersion(), 2);
        assertEq(fresh.currentBorrowIndex(), WAD);
    }

    function _assertRepresentativeMigration(LendingPool legacyImplementation) internal {
        LendingPool legacy = _deployLegacy(legacyImplementation);
        _fundAndApprove(legacy);
        _seedRepresentativeState(legacy);
        legacy.proposeUpgradeAuthority(pendingAuthority);

        vm.warp(block.timestamp + 73 days);
        priceFeed.setUpdatedAt(block.timestamp);

        RepresentativeSnapshot memory beforeState = _representativeSnapshot(legacy);
        assertEq(legacy.currentBorrowIndex(), beforeState.currentIndex);

        vm.expectEmit(false, false, false, true, address(legacy));
        emit V1_2Activated(
            beforeState.storedIndex,
            beforeState.currentIndex,
            block.timestamp - beforeState.lastIndexUpdate,
            block.timestamp
        );
        _atomicMigrate(legacy, v12Implementation);

        LendingPoolV1_2 migrated = LendingPoolV1_2(address(legacy));
        assertEq(_implementationOf(legacy), address(v12Implementation));
        assertEq(migrated.version(), "1.2");
        assertEq(LendingPoolV1_2MigrationHarness(address(migrated)).initializedVersion(), 2);
        assertEq(migrated.borrowIndex(), beforeState.currentIndex);
        assertEq(migrated.lastBorrowIndexUpdate(), block.timestamp);
        assertEq(migrated.debtBalanceOf(borrowerOne), beforeState.debtOne);
        assertEq(migrated.debtBalanceOf(borrowerTwo), beforeState.debtTwo);
        assertEq(migrated.totalDebt(), beforeState.totalDebt);
        assertEq(migrated.scaledDebtOf(borrowerOne), beforeState.scaledDebtOne);
        assertEq(migrated.scaledDebtOf(borrowerTwo), beforeState.scaledDebtTwo);
        assertEq(migrated.totalScaledDebt(), beforeState.totalScaledDebt);
        assertEq(migrated.collateralSharesOf(borrowerOne), beforeState.collateralSharesOne);
        assertEq(migrated.collateralSharesOf(borrowerTwo), beforeState.collateralSharesTwo);
        assertEq(migrated.totalCollateralShares(), beforeState.totalCollateralShares);
        assertEq(migrated.totalLiquidity(), beforeState.totalLiquidity);
        assertEq(migrated.liquidityBalanceOf(provider), beforeState.providerLiquidity);
        assertEq(_unchangedProtocolStateDigest(migrated), beforeState.unchangedProtocolState);
        assertEq(_custodyDigest(migrated), beforeState.custodyState);
        assertEq(migrated.upgradeAuthority(), beforeState.upgradeAuthority);
        assertEq(migrated.pendingUpgradeAuthority(), beforeState.pendingUpgradeAuthority);

        uint256 settledIndex = migrated.borrowIndex();
        uint256 postMigrationRate = migrated.currentBorrowRate();
        uint256 postMigrationStart = block.timestamp;
        vm.warp(postMigrationStart + 31 days);
        uint256 expectedRayIndex = BorrowIndexMath.accrueIndex(settledIndex, postMigrationRate, 31 days);
        uint256 oldPolynomialIndex = _legacyAccrue(settledIndex, postMigrationRate, 31 days);

        assertEq(migrated.currentBorrowIndex(), expectedRayIndex);
        assertNotEq(expectedRayIndex, oldPolynomialIndex);
        assertEq(migrated.lastBorrowIndexUpdate(), postMigrationStart);
    }

    function _representativeSnapshot(LendingPool legacy)
        internal
        view
        returns (RepresentativeSnapshot memory snapshot)
    {
        snapshot.storedIndex = legacy.borrowIndex();
        snapshot.lastIndexUpdate = legacy.lastBorrowIndexUpdate();
        snapshot.currentIndex = _legacyCurrentIndex(legacy);
        snapshot.debtOne = legacy.debtBalanceOf(borrowerOne);
        snapshot.debtTwo = legacy.debtBalanceOf(borrowerTwo);
        snapshot.totalDebt = legacy.totalDebt();
        snapshot.scaledDebtOne = legacy.scaledDebtOf(borrowerOne);
        snapshot.scaledDebtTwo = legacy.scaledDebtOf(borrowerTwo);
        snapshot.totalScaledDebt = legacy.totalScaledDebt();
        snapshot.collateralSharesOne = legacy.collateralSharesOf(borrowerOne);
        snapshot.collateralSharesTwo = legacy.collateralSharesOf(borrowerTwo);
        snapshot.totalCollateralShares = legacy.totalCollateralShares();
        snapshot.totalLiquidity = legacy.totalLiquidity();
        snapshot.providerLiquidity = legacy.liquidityBalanceOf(provider);
        snapshot.upgradeAuthority = legacy.upgradeAuthority();
        snapshot.pendingUpgradeAuthority = legacy.pendingUpgradeAuthority();
        snapshot.unchangedProtocolState = _unchangedProtocolStateDigest(legacy);
        snapshot.custodyState = _custodyDigest(legacy);
    }

    function _assertInactiveAccounting(LendingPoolV1_2 inactive) internal {
        vm.expectRevert(LendingPoolV1_2.V1_2AccountingInactive.selector);
        inactive.currentBorrowIndex();
        vm.expectRevert(LendingPoolV1_2.V1_2AccountingInactive.selector);
        inactive.debtBalanceOf(borrowerOne);
        vm.expectRevert(LendingPoolV1_2.V1_2AccountingInactive.selector);
        inactive.totalDebt();
        vm.expectRevert(LendingPoolV1_2.V1_2AccountingInactive.selector);
        inactive.utilizationRate();
        vm.expectRevert(LendingPoolV1_2.V1_2AccountingInactive.selector);
        inactive.currentBorrowRate();
        vm.expectRevert(LendingPoolV1_2.V1_2AccountingInactive.selector);
        inactive.availableLiquidity();
        vm.expectRevert(LendingPoolV1_2.V1_2AccountingInactive.selector);
        inactive.getHealthFactor(borrowerOne);
        vm.expectRevert(LendingPoolV1_2.V1_2AccountingInactive.selector);
        inactive.isLiquidatable(borrowerOne);
        vm.expectRevert(LendingPoolV1_2.V1_2AccountingInactive.selector);
        inactive.borrow(1);
        vm.expectRevert(LendingPoolV1_2.V1_2AccountingInactive.selector);
        inactive.repay(1);
        vm.expectRevert(LendingPoolV1_2.V1_2AccountingInactive.selector);
        inactive.liquidate(borrowerOne, 1);
        vm.expectRevert(LendingPoolV1_2.V1_2AccountingInactive.selector);
        inactive.depositLiquidity(1);
        vm.expectRevert(LendingPoolV1_2.V1_2AccountingInactive.selector);
        inactive.withdrawLiquidity(1);
        vm.expectRevert(LendingPoolV1_2.V1_2AccountingInactive.selector);
        inactive.withdrawCollateral(1);

        inactive.getCollateralAssets(borrowerOne);
        inactive.getCollateralValue(borrowerOne);
        inactive.maxBorrowOf(borrowerOne);
    }

    function _deployLegacy(LendingPool implementation) internal returns (LendingPool) {
        return _deployLendingPoolProxy(
            implementation,
            LendingPoolProxyConfig({
                priceFeed: address(priceFeed),
                vault: address(vault),
                debtAsset: address(debtToken),
                maxPriceStaleness: 500 days,
                ltvBps: 7_000,
                liquidationThresholdBps: 8_000,
                liquidationBonusBps: 500,
                baseBorrowRate: 0.05e18,
                borrowRateSlope: 0.2e18,
                initialUpgradeAuthority: address(this)
            })
        );
    }

    function _fundAndApprove(LendingPool legacy) internal {
        address[4] memory actors = [borrowerOne, borrowerTwo, provider, liquidator];
        for (uint256 i; i < actors.length; ++i) {
            collateralToken.mint(actors[i], 10_000 ether);
            debtToken.mint(actors[i], 10_000 ether);
            vm.startPrank(actors[i]);
            collateralToken.approve(address(legacy), type(uint256).max);
            debtToken.approve(address(legacy), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _seedDebt(LendingPool legacy) internal {
        vm.prank(provider);
        legacy.depositLiquidity(2_000 ether);
        vm.prank(borrowerOne);
        legacy.depositCollateral(1_000 ether);
        vm.prank(borrowerOne);
        legacy.borrow(300 ether);
    }

    function _seedRepresentativeState(LendingPool legacy) internal {
        vm.prank(provider);
        legacy.depositLiquidity(2_000 ether);
        vm.prank(borrowerOne);
        legacy.depositCollateral(1_000 ether);
        vm.prank(borrowerTwo);
        legacy.depositCollateral(800 ether);
        vm.prank(borrowerOne);
        legacy.borrow(300 ether);
        vm.prank(borrowerTwo);
        legacy.borrow(200 ether);
    }

    function _atomicMigrate(LendingPool pool, LendingPoolV1_2 implementation) internal {
        pool.upgradeToAndCall(address(implementation), abi.encodeCall(LendingPoolV1_2.migrateToV1_2, ()));
    }

    function _assertLowIndexMigrationRejected(uint256 invalidIndex) internal {
        LendingPool legacy = _deployLegacy(new LendingPool());
        vm.store(address(legacy), bytes32(uint256(8)), bytes32(invalidIndex));
        vm.warp(block.timestamp + YEAR);
        bytes32 beforeState = _stateDigest(legacy);

        vm.expectRevert(abi.encodeWithSelector(LendingPoolV1_2.BorrowIndexTooLow.selector, invalidIndex, WAD));
        _atomicMigrate(legacy, v12Implementation);

        assertEq(_stateDigest(legacy), beforeState);
    }

    function _assertRateMigrationRejected(uint256 baseRate, uint256 slope) internal {
        LendingPool legacy = _deployLegacy(new LendingPool());
        vm.store(address(legacy), bytes32(uint256(12)), bytes32(baseRate));
        vm.store(address(legacy), bytes32(uint256(13)), bytes32(slope));
        bytes32 beforeState = _stateDigest(legacy);

        vm.expectRevert(LendingPool.InvalidInterestRateModel.selector);
        _atomicMigrate(legacy, v12Implementation);

        assertEq(_stateDigest(legacy), beforeState);
    }

    function _legacyCurrentIndex(LendingPool legacy) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - legacy.lastBorrowIndexUpdate();
        uint256 storedIndex = legacy.borrowIndex();
        if (elapsed == 0) return storedIndex;
        if (legacy.totalScaledDebt() == 0) return storedIndex;

        uint256 liquidity = legacy.totalLiquidity();
        uint256 utilization;
        if (liquidity != 0) {
            uint256 storedDebt = legacy.totalScaledDebt() * storedIndex / WAD;
            utilization = storedDebt >= liquidity ? WAD : storedDebt * WAD / liquidity;
        }
        uint256 rate = legacy.baseBorrowRate() + utilization * legacy.borrowRateSlope() / WAD;
        return _legacyAccrue(storedIndex, rate, elapsed);
    }

    function _legacyAccrue(uint256 index, uint256 rate, uint256 elapsed) internal pure returns (uint256) {
        uint256 interestFactor = rate * elapsed / YEAR;
        uint256 secondOrderTerm = interestFactor * interestFactor / (2 * WAD);
        return index * (WAD + interestFactor + secondOrderTerm) / WAD;
    }

    function _stateDigest(LendingPool pool) internal view returns (bytes32) {
        return keccak256(abi.encode(_protocolStateDigest(pool), _custodyDigest(pool)));
    }

    function _protocolStateDigest(LendingPool pool) internal view returns (bytes32 digest) {
        digest = keccak256(abi.encode(vm.load(address(pool), ERC1967_IMPLEMENTATION_SLOT)));
        for (uint256 slot; slot < 18; ++slot) {
            digest = keccak256(abi.encode(digest, vm.load(address(pool), bytes32(slot))));
        }
        address[5] memory actors = [borrowerOne, borrowerTwo, provider, liquidator, pendingAuthority];
        for (uint256 mappingSlot = 15; mappingSlot < 18; ++mappingSlot) {
            for (uint256 i; i < actors.length; ++i) {
                digest = keccak256(
                    abi.encode(digest, vm.load(address(pool), keccak256(abi.encode(actors[i], mappingSlot))))
                );
            }
        }
        digest = keccak256(abi.encode(digest, vm.load(address(pool), UPGRADE_AUTHORITY_STORAGE)));
        digest = keccak256(abi.encode(digest, vm.load(address(pool), bytes32(uint256(UPGRADE_AUTHORITY_STORAGE) + 1))));
        digest = keccak256(abi.encode(digest, vm.load(address(pool), INITIALIZABLE_STORAGE)));
    }

    function _unchangedProtocolStateDigest(LendingPool pool) internal view returns (bytes32 digest) {
        for (uint256 slot; slot < 18; ++slot) {
            if (slot == 8 || slot == 9) continue;
            digest = keccak256(abi.encode(digest, vm.load(address(pool), bytes32(slot))));
        }
        address[5] memory actors = [borrowerOne, borrowerTwo, provider, liquidator, pendingAuthority];
        for (uint256 mappingSlot = 15; mappingSlot < 18; ++mappingSlot) {
            for (uint256 i; i < actors.length; ++i) {
                digest = keccak256(
                    abi.encode(digest, vm.load(address(pool), keccak256(abi.encode(actors[i], mappingSlot))))
                );
            }
        }
        digest = keccak256(abi.encode(digest, vm.load(address(pool), UPGRADE_AUTHORITY_STORAGE)));
        digest = keccak256(abi.encode(digest, vm.load(address(pool), bytes32(uint256(UPGRADE_AUTHORITY_STORAGE) + 1))));
    }

    function _custodyDigest(LendingPool pool) internal view returns (bytes32 digest) {
        address[5] memory actors = [address(pool), borrowerOne, borrowerTwo, provider, liquidator];
        for (uint256 i; i < actors.length; ++i) {
            digest = keccak256(abi.encode(digest, debtToken.balanceOf(actors[i]), collateralToken.balanceOf(actors[i])));
        }
        digest = keccak256(abi.encode(digest, collateralToken.balanceOf(address(vault))));
        digest = keccak256(abi.encode(digest, vault.balanceOf(address(pool)), vault.totalAssets(), vault.totalSupply()));
    }

    function _implementationOf(LendingPool pool) internal view returns (address) {
        return address(uint160(uint256(vm.load(address(pool), ERC1967_IMPLEMENTATION_SLOT))));
    }
}
