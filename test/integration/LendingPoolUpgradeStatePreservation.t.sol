// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {LendingPoolProxyFixture} from "../helpers/LendingPoolProxyFixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

import {LendingPool} from "../../src/core/lending/LendingPool.sol";
import {LendingPoolV1_1} from "../../src/core/lending/LendingPoolV1_1.sol";
import {CollateralVault} from "../../src/core/vault/CollateralVault.sol";

contract LendingPoolUpgradeStatePreservationTest is Test, LendingPoolProxyFixture {
    struct ConfigurationSnapshot {
        address priceFeed;
        address vault;
        address debtAsset;
        address collateralAsset;
        uint256 maxPriceStaleness;
        uint256 ltvBps;
        uint256 liquidationThresholdBps;
        uint256 liquidationBonusBps;
        uint256 borrowIndex;
        uint256 lastBorrowIndexUpdate;
        uint256 baseBorrowRate;
        uint256 borrowRateSlope;
    }

    struct AccountingSnapshot {
        uint256 totalCollateralShares;
        uint256 totalLiquidity;
        uint256 totalScaledDebt;
        uint256[2] borrowerScaledDebt;
        uint256[2] borrowerCollateralShares;
        uint256[2] providerLiquidityBalances;
    }

    struct CustodySnapshot {
        uint256 proxyDebtBalance;
        uint256 proxyVaultShareBalance;
        uint256 vaultCollateralBalance;
        uint256 vaultTotalAssets;
        uint256 vaultTotalSupply;
    }

    struct AllowanceSnapshot {
        uint256[2] borrowerCollateralToProxy;
        uint256[2] providerDebtToProxy;
        uint256[2] borrowerDebtToProxy;
        uint256 liquidatorDebtToProxy;
        uint256 proxyCollateralToVault;
    }

    struct UserBalanceSnapshot {
        uint256[2] borrowerCollateralBalances;
        uint256[2] borrowerDebtBalances;
        uint256[2] providerDebtBalances;
        uint256 liquidatorCollateralBalance;
        uint256 liquidatorDebtBalance;
    }

    struct OracleSnapshot {
        uint8 decimals;
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    struct LiveStateSnapshot {
        address proxyAddress;
        bytes32 implementationWord;
        address activeAuthority;
        address pendingAuthority;
        uint256 timestamp;
        bytes32[18] legacySlots;
        bytes32[6] mappingLeaves;
        ConfigurationSnapshot configuration;
        AccountingSnapshot accounting;
        CustodySnapshot custody;
        AllowanceSnapshot allowances;
        UserBalanceSnapshot userBalances;
        OracleSnapshot oracle;
    }

    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant LTV_BPS = 7_000;
    uint256 internal constant LIQUIDATION_THRESHOLD_BPS = 8_000;
    uint256 internal constant LIQUIDATION_BONUS_BPS = 500;
    uint256 internal constant MAX_PRICE_STALENESS = 1 days;
    uint256 internal constant BASE_BORROW_RATE = 0.05e18;
    uint256 internal constant BORROW_RATE_SLOPE = 0.2e18;

    MockERC20 internal collateralToken;
    MockERC20 internal debtToken;
    MockV3Aggregator internal priceFeed;
    CollateralVault internal vault;
    LendingPool internal pool;
    LendingPool internal v1Implementation;
    LendingPoolV1_1 internal v11Implementation;

    address internal activeAuthority;
    address internal pendingAuthority;
    address internal borrowerOne;
    address internal borrowerTwo;
    address internal liquidityProviderOne;
    address internal liquidityProviderTwo;
    address internal liquidator;

    function test_UpgradePreservesLiveAccountingCustodyAndPostUpgradeFlows() public {
        _deployAndBuildLiveState();
        _assertPreUpgradeStateIsNonTrivial();

        LiveStateSnapshot memory beforeState = _snapshotLiveState();

        assertEq(beforeState.implementationWord, _addressWord(address(v1Implementation)));

        vm.prank(activeAuthority);
        pool.upgradeToAndCall(address(v11Implementation), "");

        _assertImmediateUpgradePreservation(beforeState);
        _provePostUpgradeFlows();
    }

    function test_V1_1CheckpointsInterestAcrossLiquidityMutationsAfterUpgrade() public {
        _deployAndBuildLiveState();
        LiveStateSnapshot memory beforeState = _snapshotLiveState();

        vm.prank(activeAuthority);
        pool.upgradeToAndCall(address(v11Implementation), "");

        _assertImmediateUpgradePreservation(beforeState);
        assertEq(address(pool), beforeState.proxyAddress);
        assertEq(vm.load(address(pool), ERC1967_IMPLEMENTATION_SLOT), _addressWord(address(v11Implementation)));

        vm.warp(block.timestamp + 30 days);
        uint256 indexBeforeDeposit = pool.currentBorrowIndex();
        uint256 borrowerOneDebtBeforeDeposit = pool.debtBalanceOf(borrowerOne);
        uint256 borrowerTwoDebtBeforeDeposit = pool.debtBalanceOf(borrowerTwo);

        debtToken.mint(liquidityProviderOne, 1_000 ether);
        vm.prank(liquidityProviderOne);
        pool.depositLiquidity(1_000 ether);

        assertEq(pool.borrowIndex(), indexBeforeDeposit);
        assertEq(pool.currentBorrowIndex(), indexBeforeDeposit);
        assertEq(pool.debtBalanceOf(borrowerOne), borrowerOneDebtBeforeDeposit);
        assertEq(pool.debtBalanceOf(borrowerTwo), borrowerTwoDebtBeforeDeposit);

        vm.warp(block.timestamp + 30 days);
        uint256 indexBeforeWithdrawal = pool.currentBorrowIndex();
        uint256 borrowerOneDebtBeforeWithdrawal = pool.debtBalanceOf(borrowerOne);
        uint256 borrowerTwoDebtBeforeWithdrawal = pool.debtBalanceOf(borrowerTwo);

        vm.prank(liquidityProviderOne);
        pool.withdrawLiquidity(500 ether);

        assertEq(pool.borrowIndex(), indexBeforeWithdrawal);
        assertEq(pool.currentBorrowIndex(), indexBeforeWithdrawal);
        assertEq(pool.debtBalanceOf(borrowerOne), borrowerOneDebtBeforeWithdrawal);
        assertEq(pool.debtBalanceOf(borrowerTwo), borrowerTwoDebtBeforeWithdrawal);
        assertEq(address(pool), beforeState.proxyAddress);
        _assertImplementationsCustodyFree();
    }

    function _deployAndBuildLiveState() internal {
        activeAuthority = makeAddr("activeAuthority");
        pendingAuthority = makeAddr("pendingAuthority");
        borrowerOne = makeAddr("borrowerOne");
        borrowerTwo = makeAddr("borrowerTwo");
        liquidityProviderOne = makeAddr("liquidityProviderOne");
        liquidityProviderTwo = makeAddr("liquidityProviderTwo");
        liquidator = makeAddr("liquidator");

        collateralToken = new MockERC20("Collateral Token", "COL");
        debtToken = new MockERC20("Debt Token", "DEBT");
        priceFeed = new MockV3Aggregator(8, 1e8, block.timestamp);
        vault = new CollateralVault("Collateral Vault Share", "CVS", collateralToken);
        v1Implementation = new LendingPool();
        v11Implementation = new LendingPoolV1_1();

        pool = _deployLendingPoolProxy(v1Implementation, _proxyConfig());

        _mintAndApproveActors();

        vm.prank(liquidityProviderOne);
        pool.depositLiquidity(1_000 ether);
        vm.prank(liquidityProviderTwo);
        pool.depositLiquidity(800 ether);

        vm.prank(borrowerOne);
        pool.depositCollateral(500 ether);
        vm.prank(borrowerTwo);
        pool.depositCollateral(400 ether);

        vm.prank(borrowerOne);
        pool.borrow(250 ether);
        vm.prank(borrowerTwo);
        pool.borrow(180 ether);

        vm.warp(block.timestamp + 180 days);
        priceFeed.setUpdatedAt(block.timestamp);

        vm.prank(borrowerOne);
        pool.repay(25 ether);

        vm.prank(activeAuthority);
        pool.proposeUpgradeAuthority(pendingAuthority);
    }

    function _mintAndApproveActors() internal {
        collateralToken.mint(borrowerOne, 600 ether);
        collateralToken.mint(borrowerTwo, 500 ether);

        debtToken.mint(liquidityProviderOne, 1_000 ether);
        debtToken.mint(liquidityProviderTwo, 800 ether);
        debtToken.mint(borrowerOne, 100 ether);
        debtToken.mint(borrowerTwo, 100 ether);
        debtToken.mint(liquidator, 500 ether);

        vm.prank(borrowerOne);
        collateralToken.approve(address(pool), type(uint256).max);
        vm.prank(borrowerTwo);
        collateralToken.approve(address(pool), type(uint256).max);

        vm.prank(liquidityProviderOne);
        debtToken.approve(address(pool), type(uint256).max);
        vm.prank(liquidityProviderTwo);
        debtToken.approve(address(pool), type(uint256).max);
        vm.prank(borrowerOne);
        debtToken.approve(address(pool), type(uint256).max);
        vm.prank(borrowerTwo);
        debtToken.approve(address(pool), type(uint256).max);
        vm.prank(liquidator);
        debtToken.approve(address(pool), type(uint256).max);
    }

    function _assertPreUpgradeStateIsNonTrivial() internal view {
        assertGt(pool.liquidityBalanceOf(liquidityProviderOne), 0);
        assertGt(pool.liquidityBalanceOf(liquidityProviderTwo), 0);
        assertGt(pool.collateralSharesOf(borrowerOne), 0);
        assertGt(pool.collateralSharesOf(borrowerTwo), 0);
        assertGt(pool.scaledDebtOf(borrowerOne), 0);
        assertGt(pool.scaledDebtOf(borrowerTwo), 0);
        assertGt(pool.totalLiquidity(), 0);
        assertGt(pool.totalCollateralShares(), 0);
        assertGt(pool.totalScaledDebt(), 0);
        assertGt(pool.borrowIndex(), WAD);
        assertGt(debtToken.balanceOf(address(pool)), 0);
        assertGt(vault.balanceOf(address(pool)), 0);

        assertNotEq(activeAuthority, address(this));
        assertNotEq(activeAuthority, borrowerOne);
        assertNotEq(activeAuthority, borrowerTwo);
        assertNotEq(activeAuthority, liquidityProviderOne);
        assertNotEq(activeAuthority, liquidityProviderTwo);
        assertNotEq(pendingAuthority, address(0));
        assertNotEq(pendingAuthority, activeAuthority);
        assertEq(pool.upgradeAuthority(), activeAuthority);
        assertEq(pool.pendingUpgradeAuthority(), pendingAuthority);

        assertFalse(pool.isLiquidatable(borrowerOne));
        assertFalse(pool.isLiquidatable(borrowerTwo));
        assertGe(pool.getHealthFactor(borrowerOne), WAD);
        assertGe(pool.getHealthFactor(borrowerTwo), WAD);

        _assertImplementationsCustodyFree();
    }

    function _snapshotLiveState() internal view returns (LiveStateSnapshot memory snapshot) {
        snapshot.proxyAddress = address(pool);
        snapshot.implementationWord = vm.load(address(pool), ERC1967_IMPLEMENTATION_SLOT);
        snapshot.activeAuthority = pool.upgradeAuthority();
        snapshot.pendingAuthority = pool.pendingUpgradeAuthority();
        snapshot.timestamp = block.timestamp;

        for (uint256 slot; slot < snapshot.legacySlots.length; ++slot) {
            snapshot.legacySlots[slot] = vm.load(address(pool), bytes32(slot));
        }

        snapshot.mappingLeaves = _mappingLeaves();
        snapshot.configuration = _configurationSnapshot();
        snapshot.accounting = _accountingSnapshot();
        snapshot.custody = _custodySnapshot();
        snapshot.allowances = _allowanceSnapshot();
        snapshot.userBalances = _userBalanceSnapshot();
        snapshot.oracle = _oracleSnapshot();
    }

    function _configurationSnapshot() internal view returns (ConfigurationSnapshot memory configuration) {
        configuration = ConfigurationSnapshot({
            priceFeed: address(pool.priceFeed()),
            vault: address(pool.vault()),
            debtAsset: address(pool.debtAsset()),
            collateralAsset: address(pool.collateralAsset()),
            maxPriceStaleness: pool.maxPriceStaleness(),
            ltvBps: pool.ltvBps(),
            liquidationThresholdBps: pool.liquidationThresholdBps(),
            liquidationBonusBps: pool.liquidationBonusBps(),
            borrowIndex: pool.borrowIndex(),
            lastBorrowIndexUpdate: pool.lastBorrowIndexUpdate(),
            baseBorrowRate: pool.baseBorrowRate(),
            borrowRateSlope: pool.borrowRateSlope()
        });
    }

    function _accountingSnapshot() internal view returns (AccountingSnapshot memory accounting) {
        accounting.totalCollateralShares = pool.totalCollateralShares();
        accounting.totalLiquidity = pool.totalLiquidity();
        accounting.totalScaledDebt = pool.totalScaledDebt();
        accounting.borrowerScaledDebt[0] = pool.scaledDebtOf(borrowerOne);
        accounting.borrowerScaledDebt[1] = pool.scaledDebtOf(borrowerTwo);
        accounting.borrowerCollateralShares[0] = pool.collateralSharesOf(borrowerOne);
        accounting.borrowerCollateralShares[1] = pool.collateralSharesOf(borrowerTwo);
        accounting.providerLiquidityBalances[0] = pool.liquidityBalanceOf(liquidityProviderOne);
        accounting.providerLiquidityBalances[1] = pool.liquidityBalanceOf(liquidityProviderTwo);
    }

    function _custodySnapshot() internal view returns (CustodySnapshot memory custody) {
        custody.proxyDebtBalance = debtToken.balanceOf(address(pool));
        custody.proxyVaultShareBalance = vault.balanceOf(address(pool));
        custody.vaultCollateralBalance = collateralToken.balanceOf(address(vault));
        custody.vaultTotalAssets = vault.totalAssets();
        custody.vaultTotalSupply = vault.totalSupply();
    }

    function _allowanceSnapshot() internal view returns (AllowanceSnapshot memory allowances) {
        allowances.borrowerCollateralToProxy[0] = collateralToken.allowance(borrowerOne, address(pool));
        allowances.borrowerCollateralToProxy[1] = collateralToken.allowance(borrowerTwo, address(pool));
        allowances.providerDebtToProxy[0] = debtToken.allowance(liquidityProviderOne, address(pool));
        allowances.providerDebtToProxy[1] = debtToken.allowance(liquidityProviderTwo, address(pool));
        allowances.borrowerDebtToProxy[0] = debtToken.allowance(borrowerOne, address(pool));
        allowances.borrowerDebtToProxy[1] = debtToken.allowance(borrowerTwo, address(pool));
        allowances.liquidatorDebtToProxy = debtToken.allowance(liquidator, address(pool));
        allowances.proxyCollateralToVault = collateralToken.allowance(address(pool), address(vault));
    }

    function _userBalanceSnapshot() internal view returns (UserBalanceSnapshot memory balances) {
        balances.borrowerCollateralBalances[0] = collateralToken.balanceOf(borrowerOne);
        balances.borrowerCollateralBalances[1] = collateralToken.balanceOf(borrowerTwo);
        balances.borrowerDebtBalances[0] = debtToken.balanceOf(borrowerOne);
        balances.borrowerDebtBalances[1] = debtToken.balanceOf(borrowerTwo);
        balances.providerDebtBalances[0] = debtToken.balanceOf(liquidityProviderOne);
        balances.providerDebtBalances[1] = debtToken.balanceOf(liquidityProviderTwo);
        balances.liquidatorCollateralBalance = collateralToken.balanceOf(liquidator);
        balances.liquidatorDebtBalance = debtToken.balanceOf(liquidator);
    }

    function _oracleSnapshot() internal view returns (OracleSnapshot memory oracle) {
        oracle.decimals = priceFeed.decimals();
        (oracle.roundId, oracle.answer, oracle.startedAt, oracle.updatedAt, oracle.answeredInRound) =
            priceFeed.latestRoundData();
    }

    function _mappingLeaves() internal view returns (bytes32[6] memory leaves) {
        leaves[0] = vm.load(address(pool), _mappingLocation(borrowerOne, 15));
        leaves[1] = vm.load(address(pool), _mappingLocation(borrowerTwo, 15));
        leaves[2] = vm.load(address(pool), _mappingLocation(borrowerOne, 16));
        leaves[3] = vm.load(address(pool), _mappingLocation(borrowerTwo, 16));
        leaves[4] = vm.load(address(pool), _mappingLocation(liquidityProviderOne, 17));
        leaves[5] = vm.load(address(pool), _mappingLocation(liquidityProviderTwo, 17));
    }

    function _assertImmediateUpgradePreservation(LiveStateSnapshot memory beforeState) internal view {
        assertEq(address(pool), beforeState.proxyAddress);
        assertEq(block.timestamp, beforeState.timestamp);
        assertEq(beforeState.implementationWord, _addressWord(address(v1Implementation)));
        assertEq(vm.load(address(pool), ERC1967_IMPLEMENTATION_SLOT), _addressWord(address(v11Implementation)));
        assertEq(LendingPoolV1_1(address(pool)).version(), "1.1");

        for (uint256 slot; slot < beforeState.legacySlots.length; ++slot) {
            assertEq(vm.load(address(pool), bytes32(slot)), beforeState.legacySlots[slot]);
        }

        bytes32[6] memory leavesAfter = _mappingLeaves();
        for (uint256 leaf; leaf < beforeState.mappingLeaves.length; ++leaf) {
            assertEq(leavesAfter[leaf], beforeState.mappingLeaves[leaf]);
        }

        assertEq(pool.upgradeAuthority(), beforeState.activeAuthority);
        assertEq(pool.pendingUpgradeAuthority(), beforeState.pendingAuthority);
        _assertConfigurationUnchanged(beforeState.configuration);
        _assertAccountingUnchanged(beforeState.accounting);
        _assertCustodyUnchanged(beforeState.custody);
        _assertAllowancesUnchanged(beforeState.allowances);
        _assertUserBalancesUnchanged(beforeState.userBalances);
        _assertOracleUnchanged(beforeState.oracle);

        assertFalse(pool.isLiquidatable(borrowerOne));
        assertFalse(pool.isLiquidatable(borrowerTwo));
        assertGe(pool.getHealthFactor(borrowerOne), WAD);
        assertGe(pool.getHealthFactor(borrowerTwo), WAD);
        _assertImplementationsCustodyFree();
    }

    function _assertConfigurationUnchanged(ConfigurationSnapshot memory expected) internal view {
        assertEq(address(pool.priceFeed()), expected.priceFeed);
        assertEq(address(pool.vault()), expected.vault);
        assertEq(address(pool.debtAsset()), expected.debtAsset);
        assertEq(address(pool.collateralAsset()), expected.collateralAsset);
        assertEq(pool.maxPriceStaleness(), expected.maxPriceStaleness);
        assertEq(pool.ltvBps(), expected.ltvBps);
        assertEq(pool.liquidationThresholdBps(), expected.liquidationThresholdBps);
        assertEq(pool.liquidationBonusBps(), expected.liquidationBonusBps);
        assertEq(pool.borrowIndex(), expected.borrowIndex);
        assertEq(pool.lastBorrowIndexUpdate(), expected.lastBorrowIndexUpdate);
        assertEq(pool.baseBorrowRate(), expected.baseBorrowRate);
        assertEq(pool.borrowRateSlope(), expected.borrowRateSlope);
    }

    function _assertAccountingUnchanged(AccountingSnapshot memory expected) internal view {
        assertEq(pool.totalCollateralShares(), expected.totalCollateralShares);
        assertEq(pool.totalLiquidity(), expected.totalLiquidity);
        assertEq(pool.totalScaledDebt(), expected.totalScaledDebt);
        assertEq(pool.scaledDebtOf(borrowerOne), expected.borrowerScaledDebt[0]);
        assertEq(pool.scaledDebtOf(borrowerTwo), expected.borrowerScaledDebt[1]);
        assertEq(pool.collateralSharesOf(borrowerOne), expected.borrowerCollateralShares[0]);
        assertEq(pool.collateralSharesOf(borrowerTwo), expected.borrowerCollateralShares[1]);
        assertEq(pool.liquidityBalanceOf(liquidityProviderOne), expected.providerLiquidityBalances[0]);
        assertEq(pool.liquidityBalanceOf(liquidityProviderTwo), expected.providerLiquidityBalances[1]);
    }

    function _assertCustodyUnchanged(CustodySnapshot memory expected) internal view {
        assertEq(debtToken.balanceOf(address(pool)), expected.proxyDebtBalance);
        assertEq(vault.balanceOf(address(pool)), expected.proxyVaultShareBalance);
        assertEq(collateralToken.balanceOf(address(vault)), expected.vaultCollateralBalance);
        assertEq(vault.totalAssets(), expected.vaultTotalAssets);
        assertEq(vault.totalSupply(), expected.vaultTotalSupply);
    }

    function _assertAllowancesUnchanged(AllowanceSnapshot memory expected) internal view {
        assertEq(collateralToken.allowance(borrowerOne, address(pool)), expected.borrowerCollateralToProxy[0]);
        assertEq(collateralToken.allowance(borrowerTwo, address(pool)), expected.borrowerCollateralToProxy[1]);
        assertEq(debtToken.allowance(liquidityProviderOne, address(pool)), expected.providerDebtToProxy[0]);
        assertEq(debtToken.allowance(liquidityProviderTwo, address(pool)), expected.providerDebtToProxy[1]);
        assertEq(debtToken.allowance(borrowerOne, address(pool)), expected.borrowerDebtToProxy[0]);
        assertEq(debtToken.allowance(borrowerTwo, address(pool)), expected.borrowerDebtToProxy[1]);
        assertEq(debtToken.allowance(liquidator, address(pool)), expected.liquidatorDebtToProxy);
        assertEq(collateralToken.allowance(address(pool), address(vault)), expected.proxyCollateralToVault);
    }

    function _assertUserBalancesUnchanged(UserBalanceSnapshot memory expected) internal view {
        assertEq(collateralToken.balanceOf(borrowerOne), expected.borrowerCollateralBalances[0]);
        assertEq(collateralToken.balanceOf(borrowerTwo), expected.borrowerCollateralBalances[1]);
        assertEq(debtToken.balanceOf(borrowerOne), expected.borrowerDebtBalances[0]);
        assertEq(debtToken.balanceOf(borrowerTwo), expected.borrowerDebtBalances[1]);
        assertEq(debtToken.balanceOf(liquidityProviderOne), expected.providerDebtBalances[0]);
        assertEq(debtToken.balanceOf(liquidityProviderTwo), expected.providerDebtBalances[1]);
        assertEq(collateralToken.balanceOf(liquidator), expected.liquidatorCollateralBalance);
        assertEq(debtToken.balanceOf(liquidator), expected.liquidatorDebtBalance);
    }

    function _assertOracleUnchanged(OracleSnapshot memory expected) internal view {
        OracleSnapshot memory actual = _oracleSnapshot();
        assertEq(actual.decimals, expected.decimals);
        assertEq(actual.roundId, expected.roundId);
        assertEq(actual.answer, expected.answer);
        assertEq(actual.startedAt, expected.startedAt);
        assertEq(actual.updatedAt, expected.updatedAt);
        assertEq(actual.answeredInRound, expected.answeredInRound);
    }

    function _provePostUpgradeFlows() internal {
        _assertPostUpgradePartialRepay();
        _assertPostUpgradeAdditionalBorrow();
        _assertPostUpgradePartialLiquidation();

        assertEq(LendingPoolV1_1(address(pool)).version(), "1.1");
        assertGt(debtToken.balanceOf(address(pool)), 0);
        assertGt(vault.balanceOf(address(pool)), 0);
        assertEq(vault.balanceOf(address(pool)), pool.totalCollateralShares());
        assertEq(pool.totalLiquidity(), 1_800 ether);
        assertEq(pool.liquidityBalanceOf(liquidityProviderOne), 1_000 ether);
        assertEq(pool.liquidityBalanceOf(liquidityProviderTwo), 800 ether);
        _assertImplementationsCustodyFree();
    }

    function _assertPostUpgradePartialRepay() internal {
        uint256 repayAmount = 10 ether;
        uint256 index = pool.borrowIndex();
        uint256 scaledDebtBefore = pool.scaledDebtOf(borrowerOne);
        uint256 totalScaledDebtBefore = pool.totalScaledDebt();
        uint256 borrowerDebtTokensBefore = debtToken.balanceOf(borrowerOne);
        uint256 proxyDebtTokensBefore = debtToken.balanceOf(address(pool));
        uint256 expectedScaledRepay = repayAmount * WAD / index;

        vm.prank(borrowerOne);
        pool.repay(repayAmount);

        uint256 expectedScaledDebt = scaledDebtBefore - expectedScaledRepay;
        assertEq(pool.borrowIndex(), index);
        assertEq(pool.scaledDebtOf(borrowerOne), expectedScaledDebt);
        assertEq(pool.totalScaledDebt(), totalScaledDebtBefore - expectedScaledRepay);
        assertEq(pool.debtBalanceOf(borrowerOne), expectedScaledDebt * index / WAD);
        assertEq(debtToken.balanceOf(borrowerOne), borrowerDebtTokensBefore - repayAmount);
        assertEq(debtToken.balanceOf(address(pool)), proxyDebtTokensBefore + repayAmount);
    }

    function _assertPostUpgradeAdditionalBorrow() internal {
        uint256 borrowAmount = 20 ether;
        uint256 index = pool.borrowIndex();
        uint256 scaledDebtBefore = pool.scaledDebtOf(borrowerTwo);
        uint256 totalScaledDebtBefore = pool.totalScaledDebt();
        uint256 borrowerDebtTokensBefore = debtToken.balanceOf(borrowerTwo);
        uint256 proxyDebtTokensBefore = debtToken.balanceOf(address(pool));
        uint256 expectedScaledBorrow = borrowAmount * WAD / index;

        vm.prank(borrowerTwo);
        pool.borrow(borrowAmount);

        uint256 expectedScaledDebt = scaledDebtBefore + expectedScaledBorrow;
        assertEq(pool.borrowIndex(), index);
        assertEq(pool.scaledDebtOf(borrowerTwo), expectedScaledDebt);
        assertEq(pool.totalScaledDebt(), totalScaledDebtBefore + expectedScaledBorrow);
        assertEq(pool.debtBalanceOf(borrowerTwo), expectedScaledDebt * index / WAD);
        assertEq(debtToken.balanceOf(borrowerTwo), borrowerDebtTokensBefore + borrowAmount);
        assertEq(debtToken.balanceOf(address(pool)), proxyDebtTokensBefore - borrowAmount);
        assertLe(pool.debtBalanceOf(borrowerTwo), pool.maxBorrowOf(borrowerTwo));
        assertGe(pool.getHealthFactor(borrowerTwo), WAD);
    }

    function _assertPostUpgradePartialLiquidation() internal {
        priceFeed.setAnswer(5e7);
        assertTrue(pool.isLiquidatable(borrowerTwo));

        uint256 repayAmount = 40 ether;
        uint256 index = pool.borrowIndex();
        uint256 expectedScaledRepay = repayAmount * WAD / index;
        uint256 expectedSeizedAssets = repayAmount * (BPS + LIQUIDATION_BONUS_BPS) / BPS * 2;
        uint256 expectedSeizedShares = vault.previewWithdraw(expectedSeizedAssets);

        uint256 borrowerScaledDebtBefore = pool.scaledDebtOf(borrowerTwo);
        uint256 totalScaledDebtBefore = pool.totalScaledDebt();
        uint256 borrowerSharesBefore = pool.collateralSharesOf(borrowerTwo);
        uint256 totalSharesBefore = pool.totalCollateralShares();
        CustodySnapshot memory custodyBefore = _custodySnapshot();
        uint256 liquidatorDebtBefore = debtToken.balanceOf(liquidator);
        uint256 liquidatorCollateralBefore = collateralToken.balanceOf(liquidator);

        vm.prank(liquidator);
        pool.liquidate(borrowerTwo, repayAmount);

        uint256 expectedBorrowerScaledDebt = borrowerScaledDebtBefore - expectedScaledRepay;
        assertEq(pool.borrowIndex(), index);
        assertEq(pool.scaledDebtOf(borrowerTwo), expectedBorrowerScaledDebt);
        assertEq(pool.totalScaledDebt(), totalScaledDebtBefore - expectedScaledRepay);
        assertEq(pool.debtBalanceOf(borrowerTwo), expectedBorrowerScaledDebt * index / WAD);
        assertEq(pool.collateralSharesOf(borrowerTwo), borrowerSharesBefore - expectedSeizedShares);
        assertEq(pool.totalCollateralShares(), totalSharesBefore - expectedSeizedShares);

        assertEq(debtToken.balanceOf(address(pool)), custodyBefore.proxyDebtBalance + repayAmount);
        assertEq(vault.balanceOf(address(pool)), custodyBefore.proxyVaultShareBalance - expectedSeizedShares);
        assertEq(collateralToken.balanceOf(address(vault)), custodyBefore.vaultCollateralBalance - expectedSeizedAssets);
        assertEq(vault.totalAssets(), custodyBefore.vaultTotalAssets - expectedSeizedAssets);
        assertEq(vault.totalSupply(), custodyBefore.vaultTotalSupply - expectedSeizedShares);
        assertEq(debtToken.balanceOf(liquidator), liquidatorDebtBefore - repayAmount);
        assertEq(collateralToken.balanceOf(liquidator), liquidatorCollateralBefore + expectedSeizedAssets);
    }

    function _assertImplementationsCustodyFree() internal view {
        _assertImplementationCustodyFree(address(v1Implementation));
        _assertImplementationCustodyFree(address(v11Implementation));
    }

    function _assertImplementationCustodyFree(address implementation) internal view {
        assertEq(collateralToken.balanceOf(implementation), 0);
        assertEq(debtToken.balanceOf(implementation), 0);
        assertEq(vault.balanceOf(implementation), 0);
        assertEq(collateralToken.allowance(implementation, address(vault)), 0);
    }

    function _proxyConfig() internal view returns (LendingPoolProxyConfig memory) {
        return LendingPoolProxyConfig({
            priceFeed: address(priceFeed),
            vault: address(vault),
            debtAsset: address(debtToken),
            maxPriceStaleness: MAX_PRICE_STALENESS,
            ltvBps: LTV_BPS,
            liquidationThresholdBps: LIQUIDATION_THRESHOLD_BPS,
            liquidationBonusBps: LIQUIDATION_BONUS_BPS,
            baseBorrowRate: BASE_BORROW_RATE,
            borrowRateSlope: BORROW_RATE_SLOPE,
            initialUpgradeAuthority: activeAuthority
        });
    }

    function _mappingLocation(address account, uint256 mappingSlot) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, mappingSlot));
    }

    function _addressWord(address value) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }
}
