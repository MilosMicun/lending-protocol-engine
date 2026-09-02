// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {CollateralVault} from "../../src/core/vault/CollateralVault.sol";
import {LendingPool} from "../../src/core/lending/LendingPool.sol";
import {RunSepoliaDemoFlow} from "../../script/RunSepoliaDemoFlow.s.sol";
import {LendingPoolProxyFixture} from "../helpers/LendingPoolProxyFixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract RunSepoliaDemoFlowTest is Test, LendingPoolProxyFixture {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 internal constant WAD = 1e18;
    bytes32 internal constant FIELD_POOL_VAULT = "poolVault";
    bytes32 internal constant FIELD_VAULT_ASSET = "vaultAsset";
    bytes32 internal constant FIELD_POOL_DEBT_ASSET = "poolDebtAsset";
    bytes32 internal constant FIELD_POOL_COLLATERAL_ASSET = "poolCollateralAsset";
    bytes32 internal constant FIELD_POOL_PRICE_FEED = "poolPriceFeed";
    bytes32 internal constant FIELD_LIQUIDITY_DEPOSIT_AMOUNT = "liquidityDepositAmount";
    bytes32 internal constant FIELD_COLLATERAL_DEPOSIT_AMOUNT = "collateralDepositAmount";
    bytes32 internal constant FIELD_BORROW_AMOUNT = "borrowAmount";
    bytes32 internal constant FIELD_PARTIAL_REPAY_AMOUNT = "partialRepayAmount";
    bytes32 internal constant FIELD_UPGRADE_AUTHORITY = "upgradeAuthority";
    address internal safe;
    address internal actor;
    MockERC20 internal collateral;
    MockERC20 internal debt;
    MockV3Aggregator internal feed;
    CollateralVault internal vault;
    LendingPool internal pool;
    RunSepoliaDemoFlow internal flow;

    function setUp() public {
        vm.chainId(SEPOLIA_CHAIN_ID);
        safe = makeAddr("safe");
        actor = makeAddr("actor");
        vm.etch(safe, hex"01");
        collateral = new MockERC20("Sepolia Demo Ether", "sdETH");
        debt = new MockERC20("Sepolia Demo USD", "sdUSD");
        feed = new MockV3Aggregator(8, 2_500e8, block.timestamp);
        vault = new CollateralVault("Demo collateral vault", "vSdETH", collateral);
        (pool,) = _deployLendingPoolProxy(
            LendingPoolProxyConfig({
                priceFeed: address(feed),
                vault: address(vault),
                debtAsset: address(debt),
                maxPriceStaleness: 1 days,
                ltvBps: 7_000,
                liquidationThresholdBps: 8_000,
                liquidationBonusBps: 500,
                baseBorrowRate: 0,
                borrowRateSlope: 0,
                initialUpgradeAuthority: safe
            })
        );
        collateral.mint(actor, 10e18);
        debt.mint(actor, 20_000e18);
        flow = new RunSepoliaDemoFlow();
    }

    function test_CompleteRepresentativeFlowUsesExactApprovalsAndPreservesWiring() public {
        RunSepoliaDemoFlow.FlowConfig memory config = _validConfig();
        RunSepoliaDemoFlow.FlowResult memory result = flow.execute(config);

        assertEq(result.afterFlow.actorLiquidityBalance, config.liquidityDepositAmount);
        assertEq(result.afterFlow.actorCollateralShares, config.collateralDepositAmount);
        assertGt(result.afterBorrow.actorScaledDebt, 0);
        assertGt(result.afterFlow.actorScaledDebt, 0);
        assertLt(result.afterFlow.actorScaledDebt, result.afterBorrow.actorScaledDebt);
        assertEq(collateral.balanceOf(address(vault)), config.collateralDepositAmount);
        assertEq(debt.allowance(actor, address(pool)), 0);
        assertEq(collateral.allowance(actor, address(pool)), 0);
        assertEq(pool.upgradeAuthority(), safe);
        assertEq(pool.pendingUpgradeAuthority(), address(0));
        assertEq(address(pool.vault()), address(vault));
        assertEq(address(pool.collateralAsset()), address(collateral));
        assertEq(address(pool.debtAsset()), address(debt));
        assertEq(address(pool.priceFeed()), address(feed));
    }

    function test_RevertsForConfiguredOrRuntimeChainMismatch() public {
        RunSepoliaDemoFlow.FlowConfig memory config = _validConfig();
        config.expectedChainId = 1;
        vm.expectRevert(abi.encodeWithSelector(RunSepoliaDemoFlow.InvalidExpectedChainId.selector, uint256(1)));
        flow.validateConfig(config);

        vm.chainId(1);
        vm.expectRevert(
            abi.encodeWithSelector(RunSepoliaDemoFlow.UnexpectedChainId.selector, SEPOLIA_CHAIN_ID, uint256(1))
        );
        flow.validateConfig(_validConfig());
    }

    function test_RevertsForZeroAndCodeLessRequiredAddresses() public {
        _expectInvalidAddress(_validConfig(), "lendingPoolProxy");
        _expectInvalidAddress(_validConfig(), "collateralVault");
        _expectInvalidAddress(_validConfig(), "collateralToken");
        _expectInvalidAddress(_validConfig(), "debtToken");
        _expectInvalidAddress(_validConfig(), "priceFeed");
        _expectInvalidAddress(_validConfig(), "expectedSafeAuthority");
        _expectInvalidAddress(_validConfig(), "demoActor");

        RunSepoliaDemoFlow.FlowConfig memory config = _validConfig();
        config.lendingPoolProxy = makeAddr("codeLessPool");
        _expectCodeLess(config, "lendingPoolProxy", config.lendingPoolProxy);
        config = _validConfig();
        config.collateralVault = makeAddr("codeLessVault");
        _expectCodeLess(config, "collateralVault", config.collateralVault);
        config = _validConfig();
        config.collateralToken = makeAddr("codeLessCollateral");
        _expectCodeLess(config, "collateralToken", config.collateralToken);
        config = _validConfig();
        config.debtToken = makeAddr("codeLessDebt");
        _expectCodeLess(config, "debtToken", config.debtToken);
        config = _validConfig();
        config.priceFeed = makeAddr("codeLessFeed");
        _expectCodeLess(config, "priceFeed", config.priceFeed);
        config = _validConfig();
        config.expectedSafeAuthority = makeAddr("codeLessSafe");
        _expectCodeLess(config, "expectedSafeAuthority", config.expectedSafeAuthority);
    }

    function test_RevertsForWiringAndAuthorityMismatches() public {
        RunSepoliaDemoFlow.FlowConfig memory config = _validConfig();
        config.collateralVault = address(new CollateralVault("Other", "OTH", collateral));
        vm.expectRevert(
            abi.encodeWithSelector(
                RunSepoliaDemoFlow.ConfigurationMismatch.selector,
                FIELD_POOL_VAULT,
                config.collateralVault,
                address(vault)
            )
        );
        flow.validateConfig(config);

        config = _validConfig();
        vm.mockCall(address(pool), abi.encodeWithSignature("collateralAsset()"), abi.encode(address(debt)));
        vm.expectRevert(
            abi.encodeWithSelector(
                RunSepoliaDemoFlow.ConfigurationMismatch.selector,
                FIELD_POOL_COLLATERAL_ASSET,
                address(collateral),
                address(debt)
            )
        );
        flow.validateConfig(config);
        vm.clearMockedCalls();

        config = _validConfig();
        config.collateralToken = address(debt);
        vm.expectRevert(
            abi.encodeWithSelector(
                RunSepoliaDemoFlow.ConfigurationMismatch.selector, FIELD_VAULT_ASSET, address(debt), address(collateral)
            )
        );
        flow.validateConfig(config);

        config = _validConfig();
        vm.mockCall(address(feed), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.expectRevert(abi.encodeWithSelector(RunSepoliaDemoFlow.UnexpectedFeedDecimals.selector, uint8(8), uint8(18)));
        flow.validateConfig(config);
        vm.clearMockedCalls();

        config = _validConfig();
        config.debtToken = address(collateral);
        vm.expectRevert(
            abi.encodeWithSelector(
                RunSepoliaDemoFlow.ConfigurationMismatch.selector,
                FIELD_POOL_DEBT_ASSET,
                address(collateral),
                address(debt)
            )
        );
        flow.validateConfig(config);

        config = _validConfig();
        MockV3Aggregator otherFeed = new MockV3Aggregator(8, 2_500e8, block.timestamp);
        config.priceFeed = address(otherFeed);
        vm.expectRevert(
            abi.encodeWithSelector(
                RunSepoliaDemoFlow.ConfigurationMismatch.selector,
                FIELD_POOL_PRICE_FEED,
                address(otherFeed),
                address(feed)
            )
        );
        flow.validateConfig(config);

        config = _validConfig();
        address otherSafe = makeAddr("otherSafe");
        vm.etch(otherSafe, hex"01");
        config.expectedSafeAuthority = otherSafe;
        vm.expectRevert(abi.encodeWithSelector(RunSepoliaDemoFlow.UnexpectedUpgradeAuthority.selector, otherSafe, safe));
        flow.validateConfig(config);
    }

    function test_RevertsWhenDemoActorHasRuntimeCode() public {
        RunSepoliaDemoFlow.FlowConfig memory config = _validConfig();
        config.demoActor = address(vault);

        vm.expectRevert(abi.encodeWithSelector(RunSepoliaDemoFlow.DemoActorHasCode.selector, address(vault)));
        flow.validateConfig(config);
    }

    function test_RevertsForPendingAuthorityActorAndInvalidAmounts() public {
        vm.prank(safe);
        pool.proposeUpgradeAuthority(actor);
        vm.expectRevert(abi.encodeWithSelector(RunSepoliaDemoFlow.UnexpectedPendingUpgradeAuthority.selector, actor));
        flow.validateConfig(_validConfig());

        // Fresh fixture state isolates the remaining independent configuration checks.
        setUp();
        RunSepoliaDemoFlow.FlowConfig memory config = _validConfig();
        config.demoActor = safe;
        vm.expectRevert(abi.encodeWithSelector(RunSepoliaDemoFlow.DemoActorIsSafe.selector, safe, safe));
        flow.validateConfig(config);

        config = _validConfig();
        config.liquidityDepositAmount = 0;
        vm.expectRevert(
            abi.encodeWithSelector(RunSepoliaDemoFlow.ZeroActionAmount.selector, FIELD_LIQUIDITY_DEPOSIT_AMOUNT)
        );
        flow.validateConfig(config);
        config = _validConfig();
        config.collateralDepositAmount = 0;
        vm.expectRevert(
            abi.encodeWithSelector(RunSepoliaDemoFlow.ZeroActionAmount.selector, FIELD_COLLATERAL_DEPOSIT_AMOUNT)
        );
        flow.validateConfig(config);
        config = _validConfig();
        config.borrowAmount = 0;
        vm.expectRevert(abi.encodeWithSelector(RunSepoliaDemoFlow.ZeroActionAmount.selector, FIELD_BORROW_AMOUNT));
        flow.validateConfig(config);
        config = _validConfig();
        config.partialRepayAmount = 0;
        vm.expectRevert(
            abi.encodeWithSelector(RunSepoliaDemoFlow.ZeroActionAmount.selector, FIELD_PARTIAL_REPAY_AMOUNT)
        );
        flow.validateConfig(config);
        config = _validConfig();
        config.partialRepayAmount = config.borrowAmount;
        vm.expectRevert(
            abi.encodeWithSelector(
                RunSepoliaDemoFlow.RepayNotPartial.selector, config.borrowAmount, config.borrowAmount
            )
        );
        flow.validateConfig(config);
    }

    function test_RevertsWhenExistingDebtMakesProjectedTotalDebtUnsafe() public {
        vm.startPrank(actor);
        debt.approve(address(pool), 10_000e18);
        pool.depositLiquidity(10_000e18);
        collateral.approve(address(pool), 1e18);
        pool.depositCollateral(1e18);
        pool.borrow(1_500e18);
        vm.stopPrank();

        RunSepoliaDemoFlow.FlowConfig memory config = _validConfig();
        config.borrowAmount = 2_001e18;
        config.partialRepayAmount = 1_000e18;
        assertLt(config.borrowAmount, 3_500e18);
        vm.expectRevert(
            abi.encodeWithSelector(RunSepoliaDemoFlow.UnsafeBorrowConfiguration.selector, 3_501e18, 3_500e18)
        );
        flow.validateConfig(config);
    }

    function test_RevertsWhenAccruedIndexRoundsPartialRepaymentToAllProjectedScaledDebt() public {
        _replacePoolWithBaseBorrowRate(WAD);
        address liquidityProvider = makeAddr("liquidityProvider");
        address accrualBorrower = makeAddr("accrualBorrower");
        debt.mint(liquidityProvider, 10_000e18);
        collateral.mint(accrualBorrower, 1e18);

        vm.startPrank(liquidityProvider);
        debt.approve(address(pool), 10_000e18);
        pool.depositLiquidity(10_000e18);
        vm.stopPrank();
        vm.startPrank(accrualBorrower);
        collateral.approve(address(pool), 1e18);
        pool.depositCollateral(1e18);
        pool.borrow(1e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 20 * 365 days);
        feed.setUpdatedAt(block.timestamp);

        uint256 accruedIndex = pool.currentBorrowIndex();
        uint256 rawAmountForOneScaledUnit = (accruedIndex + WAD - 1) / WAD;
        RunSepoliaDemoFlow.FlowConfig memory config = _validConfig();
        config.borrowAmount = rawAmountForOneScaledUnit + 1;
        config.partialRepayAmount = rawAmountForOneScaledUnit;
        assertEq(config.borrowAmount * WAD / accruedIndex, 1);
        assertEq(config.partialRepayAmount * WAD / accruedIndex, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                RunSepoliaDemoFlow.ProjectedRepaymentClearsScaledDebt.selector, uint256(1), uint256(1)
            )
        );
        flow.validateConfig(config);
    }

    function test_RevertsForInsufficientBalancesLiquidityAndUnsafeBorrow() public {
        RunSepoliaDemoFlow.FlowConfig memory config = _validConfig();
        config.liquidityDepositAmount = debt.balanceOf(actor) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                RunSepoliaDemoFlow.InsufficientActorDebtBalance.selector,
                config.liquidityDepositAmount,
                debt.balanceOf(actor)
            )
        );
        flow.validateConfig(config);

        config = _validConfig();
        config.collateralDepositAmount = collateral.balanceOf(actor) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                RunSepoliaDemoFlow.InsufficientActorCollateralBalance.selector,
                config.collateralDepositAmount,
                collateral.balanceOf(actor)
            )
        );
        flow.validateConfig(config);

        config = _validConfig();
        config.borrowAmount = config.liquidityDepositAmount + 1;
        config.partialRepayAmount = 1e18;
        vm.expectRevert(
            abi.encodeWithSelector(
                RunSepoliaDemoFlow.InsufficientPoolLiquidity.selector,
                config.borrowAmount,
                config.liquidityDepositAmount
            )
        );
        flow.validateConfig(config);

        config = _validConfig();
        config.borrowAmount = 2_000e18;
        config.partialRepayAmount = 1e18;
        vm.expectRevert(
            abi.encodeWithSelector(RunSepoliaDemoFlow.UnsafeBorrowConfiguration.selector, 2_000e18, 1_750e18)
        );
        flow.validateConfig(config);
    }

    function test_PostFlowVerificationRejectsChangedAuthoritySnapshot() public {
        RunSepoliaDemoFlow.FlowConfig memory config = _validConfig();
        RunSepoliaDemoFlow.FlowResult memory result = flow.execute(config);
        result.afterFlow.authority = actor;

        vm.expectRevert(
            abi.encodeWithSelector(
                RunSepoliaDemoFlow.PostFlowAddressVerificationFailed.selector, FIELD_UPGRADE_AUTHORITY, safe, actor
            )
        );
        flow.verifyPostFlow(config, result);
    }

    function _validConfig() internal view returns (RunSepoliaDemoFlow.FlowConfig memory) {
        return RunSepoliaDemoFlow.FlowConfig({
            expectedChainId: SEPOLIA_CHAIN_ID,
            lendingPoolProxy: address(pool),
            collateralVault: address(vault),
            collateralToken: address(collateral),
            debtToken: address(debt),
            priceFeed: address(feed),
            expectedSafeAuthority: safe,
            demoActor: actor,
            liquidityDepositAmount: 10_000e18,
            collateralDepositAmount: 1e18,
            borrowAmount: 1_000e18,
            partialRepayAmount: 250e18
        });
    }

    function _expectInvalidAddress(RunSepoliaDemoFlow.FlowConfig memory config, bytes32 field) internal {
        if (field == "lendingPoolProxy") config.lendingPoolProxy = address(0);
        if (field == "collateralVault") config.collateralVault = address(0);
        if (field == "collateralToken") config.collateralToken = address(0);
        if (field == "debtToken") config.debtToken = address(0);
        if (field == "priceFeed") config.priceFeed = address(0);
        if (field == "expectedSafeAuthority") config.expectedSafeAuthority = address(0);
        if (field == "demoActor") config.demoActor = address(0);
        vm.expectRevert(abi.encodeWithSelector(RunSepoliaDemoFlow.InvalidAddress.selector, field, address(0)));
        flow.validateConfig(config);
    }

    function _expectCodeLess(RunSepoliaDemoFlow.FlowConfig memory config, bytes32 field, address account) internal {
        vm.expectRevert(abi.encodeWithSelector(RunSepoliaDemoFlow.AddressHasNoCode.selector, field, account));
        flow.validateConfig(config);
    }

    function _replacePoolWithBaseBorrowRate(uint256 baseBorrowRate) internal {
        vault = new CollateralVault("Demo collateral vault", "vSdETH", collateral);
        (pool,) = _deployLendingPoolProxy(
            LendingPoolProxyConfig({
                priceFeed: address(feed),
                vault: address(vault),
                debtAsset: address(debt),
                maxPriceStaleness: 1 days,
                ltvBps: 7_000,
                liquidationThresholdBps: 8_000,
                liquidationBonusBps: 500,
                baseBorrowRate: baseBorrowRate,
                borrowRateSlope: 0,
                initialUpgradeAuthority: safe
            })
        );
    }
}
