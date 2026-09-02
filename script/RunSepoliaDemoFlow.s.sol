// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LendingPool} from "../src/core/lending/LendingPool.sol";
import {CollateralVault} from "../src/core/vault/CollateralVault.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {OracleLib} from "../src/lib/OracleLib.sol";

/// @notice Runs one explicitly configured educational Sepolia representative flow.
/// @dev Calls are only simulated unless a reviewer later supplies --broadcast and the configured external account.
contract RunSepoliaDemoFlow is Script {
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint8 internal constant EXPECTED_FEED_DECIMALS = 8;

    struct FlowConfig {
        uint256 expectedChainId;
        address lendingPoolProxy;
        address collateralVault;
        address collateralToken;
        address debtToken;
        address priceFeed;
        address expectedSafeAuthority;
        address demoActor;
        uint256 liquidityDepositAmount;
        uint256 collateralDepositAmount;
        uint256 borrowAmount;
        uint256 partialRepayAmount;
    }

    struct Snapshot {
        uint256 actorDebtTokenBalance;
        uint256 actorCollateralTokenBalance;
        uint256 poolDebtTokenBalance;
        uint256 vaultCollateralTokenBalance;
        uint256 actorLiquidityBalance;
        uint256 actorCollateralShares;
        uint256 actorScaledDebt;
        uint256 actorDebt;
        address vault;
        address collateral;
        address debt;
        address feed;
        address authority;
        address pendingAuthority;
    }

    struct FlowResult {
        Snapshot beforeFlow;
        Snapshot afterBorrow;
        Snapshot afterFlow;
    }

    error InvalidExpectedChainId(uint256 configuredChainId);
    error UnexpectedChainId(uint256 expectedChainId, uint256 actualChainId);
    error InvalidAddress(bytes32 field, address account);
    error AddressHasNoCode(bytes32 field, address account);
    error ConfigurationMismatch(bytes32 field, address expectedAddress, address actualAddress);
    error UnexpectedFeedDecimals(uint8 expectedDecimals, uint8 actualDecimals);
    error UnexpectedUpgradeAuthority(address expectedAuthority, address actualAuthority);
    error UnexpectedPendingUpgradeAuthority(address actualAuthority);
    error DemoActorIsSafe(address actor, address safe);
    error DemoActorHasCode(address actor);
    error ZeroActionAmount(bytes32 action);
    error RepayNotPartial(uint256 repayAmount, uint256 borrowAmount);
    error InsufficientActorDebtBalance(uint256 requiredAmount, uint256 availableAmount);
    error InsufficientActorCollateralBalance(uint256 requiredAmount, uint256 availableAmount);
    error InsufficientPoolLiquidity(uint256 requestedAmount, uint256 availableAmount);
    error UnsafeBorrowConfiguration(uint256 requestedAmount, uint256 maxBorrowAmount);
    error ZeroProjectedCollateralShares(uint256 collateralDepositAmount);
    error ZeroProjectedScaledDebt(bytes32 action, uint256 amount, uint256 borrowIndex);
    error ProjectedRepaymentClearsScaledDebt(uint256 projectedScaledDebt, uint256 projectedScaledRepayment);
    error PostFlowVerificationFailed(bytes32 field, uint256 expectedValue, uint256 actualValue);
    error PostFlowAddressVerificationFailed(bytes32 field, address expectedAddress, address actualAddress);

    function run() external returns (FlowResult memory result) {
        FlowConfig memory config = _readFlowConfig();
        result = execute(config);
        _logResult(config, result);
    }

    /// @notice Testable entry point. In a Forge script this binds every transaction to `demoActor`.
    function execute(FlowConfig memory config) public returns (FlowResult memory result) {
        validateConfig(config);
        result.beforeFlow = _snapshot(config);

        vm.startBroadcast(config.demoActor);
        IERC20(config.debtToken).approve(config.lendingPoolProxy, config.liquidityDepositAmount);
        LendingPool(config.lendingPoolProxy).depositLiquidity(config.liquidityDepositAmount);
        IERC20(config.collateralToken).approve(config.lendingPoolProxy, config.collateralDepositAmount);
        LendingPool(config.lendingPoolProxy).depositCollateral(config.collateralDepositAmount);
        LendingPool(config.lendingPoolProxy).borrow(config.borrowAmount);
        result.afterBorrow = _snapshot(config);
        IERC20(config.debtToken).approve(config.lendingPoolProxy, config.partialRepayAmount);
        LendingPool(config.lendingPoolProxy).repay(config.partialRepayAmount);
        vm.stopBroadcast();

        result.afterFlow = _snapshot(config);
        verifyPostFlow(config, result);
    }

    /// @notice Read-only preflight for both the dry run and the later, explicitly approved broadcast.
    function validateConfig(FlowConfig memory config) public view {
        if (config.expectedChainId != SEPOLIA_CHAIN_ID) revert InvalidExpectedChainId(config.expectedChainId);
        if (block.chainid != config.expectedChainId) revert UnexpectedChainId(config.expectedChainId, block.chainid);

        _validateAddress("lendingPoolProxy", config.lendingPoolProxy);
        _validateAddress("collateralVault", config.collateralVault);
        _validateAddress("collateralToken", config.collateralToken);
        _validateAddress("debtToken", config.debtToken);
        _validateAddress("priceFeed", config.priceFeed);
        _validateAddress("expectedSafeAuthority", config.expectedSafeAuthority);
        if (config.demoActor == address(0)) revert InvalidAddress("demoActor", config.demoActor);
        if (config.demoActor == config.expectedSafeAuthority) {
            revert DemoActorIsSafe(config.demoActor, config.expectedSafeAuthority);
        }
        if (config.demoActor.code.length != 0) revert DemoActorHasCode(config.demoActor);

        LendingPool pool = LendingPool(config.lendingPoolProxy);
        CollateralVault vault = CollateralVault(config.collateralVault);
        _checkAddress("poolVault", config.collateralVault, address(pool.vault()));
        _checkAddress("vaultAsset", config.collateralToken, vault.asset());
        _checkAddress("poolCollateralAsset", config.collateralToken, address(pool.collateralAsset()));
        _checkAddress("poolDebtAsset", config.debtToken, address(pool.debtAsset()));
        _checkAddress("poolPriceFeed", config.priceFeed, address(pool.priceFeed()));
        if (IPriceFeed(config.priceFeed).decimals() != EXPECTED_FEED_DECIMALS) {
            revert UnexpectedFeedDecimals(EXPECTED_FEED_DECIMALS, IPriceFeed(config.priceFeed).decimals());
        }
        if (pool.upgradeAuthority() != config.expectedSafeAuthority) {
            revert UnexpectedUpgradeAuthority(config.expectedSafeAuthority, pool.upgradeAuthority());
        }
        if (pool.pendingUpgradeAuthority() != address(0)) {
            revert UnexpectedPendingUpgradeAuthority(pool.pendingUpgradeAuthority());
        }

        if (config.liquidityDepositAmount == 0) revert ZeroActionAmount("liquidityDepositAmount");
        if (config.collateralDepositAmount == 0) revert ZeroActionAmount("collateralDepositAmount");
        if (config.borrowAmount == 0) revert ZeroActionAmount("borrowAmount");
        if (config.partialRepayAmount == 0) revert ZeroActionAmount("partialRepayAmount");
        if (config.partialRepayAmount >= config.borrowAmount) {
            revert RepayNotPartial(config.partialRepayAmount, config.borrowAmount);
        }

        uint256 debtBalance = IERC20(config.debtToken).balanceOf(config.demoActor);
        if (debtBalance < config.liquidityDepositAmount) {
            revert InsufficientActorDebtBalance(config.liquidityDepositAmount, debtBalance);
        }
        uint256 collateralBalance = IERC20(config.collateralToken).balanceOf(config.demoActor);
        if (collateralBalance < config.collateralDepositAmount) {
            revert InsufficientActorCollateralBalance(config.collateralDepositAmount, collateralBalance);
        }

        _validateProjectedBorrow(pool, vault, config);
    }

    function _validateProjectedBorrow(LendingPool pool, CollateralVault vault, FlowConfig memory config) internal view {
        uint256 availableLiquidity = pool.availableLiquidity();
        if (
            config.borrowAmount > availableLiquidity
                && config.borrowAmount - availableLiquidity > config.liquidityDepositAmount
        ) {
            revert InsufficientPoolLiquidity(config.borrowAmount, availableLiquidity + config.liquidityDepositAmount);
        }

        uint256 projectedShares = vault.previewDeposit(config.collateralDepositAmount);
        if (projectedShares == 0) revert ZeroProjectedCollateralShares(config.collateralDepositAmount);
        uint256 projectedAssets = vault.convertToAssets(pool.collateralSharesOf(config.demoActor) + projectedShares);
        uint256 priceWad = OracleLib.getFreshPriceWad(IPriceFeed(config.priceFeed), pool.maxPriceStaleness());
        uint256 projectedMaxBorrow = projectedAssets * priceWad / WAD * pool.ltvBps() / BPS;
        uint256 projectedTotalDebt = pool.debtBalanceOf(config.demoActor) + config.borrowAmount;
        if (projectedTotalDebt > projectedMaxBorrow) {
            revert UnsafeBorrowConfiguration(projectedTotalDebt, projectedMaxBorrow);
        }

        uint256 currentIndex = pool.currentBorrowIndex();
        uint256 projectedScaledBorrow = config.borrowAmount * WAD / currentIndex;
        if (projectedScaledBorrow == 0) {
            revert ZeroProjectedScaledDebt("borrowAmount", config.borrowAmount, currentIndex);
        }
        uint256 projectedScaledRepayment = config.partialRepayAmount * WAD / currentIndex;
        if (projectedScaledRepayment == 0) {
            revert ZeroProjectedScaledDebt("partialRepayAmount", config.partialRepayAmount, currentIndex);
        }
        uint256 projectedScaledDebt = pool.scaledDebtOf(config.demoActor) + projectedScaledBorrow;
        if (projectedScaledRepayment >= projectedScaledDebt) {
            revert ProjectedRepaymentClearsScaledDebt(projectedScaledDebt, projectedScaledRepayment);
        }
    }

    function verifyPostFlow(FlowConfig memory config, FlowResult memory result) public view {
        Snapshot memory beforeFlow = result.beforeFlow;
        Snapshot memory afterBorrow = result.afterBorrow;
        Snapshot memory afterFlow = result.afterFlow;

        _verifyUint(
            "actorLiquidityBalance",
            beforeFlow.actorLiquidityBalance + config.liquidityDepositAmount,
            afterFlow.actorLiquidityBalance
        );
        if (afterFlow.actorCollateralShares <= beforeFlow.actorCollateralShares) {
            revert PostFlowVerificationFailed(
                "actorCollateralSharesIncrease", beforeFlow.actorCollateralShares + 1, afterFlow.actorCollateralShares
            );
        }
        if (afterBorrow.actorScaledDebt == 0) {
            revert PostFlowVerificationFailed("borrowCreatedScaledDebt", 1, afterBorrow.actorScaledDebt);
        }
        if (afterFlow.actorScaledDebt == 0 || afterFlow.actorScaledDebt >= afterBorrow.actorScaledDebt) {
            revert PostFlowVerificationFailed(
                "partialRepayScaledDebt", afterBorrow.actorScaledDebt - 1, afterFlow.actorScaledDebt
            );
        }
        if (afterFlow.actorDebt >= afterBorrow.actorDebt) {
            revert PostFlowVerificationFailed("partialRepayDebt", afterBorrow.actorDebt - 1, afterFlow.actorDebt);
        }

        _verifyUint(
            "actorDebtTokenBalanceAfterBorrow",
            beforeFlow.actorDebtTokenBalance - config.liquidityDepositAmount + config.borrowAmount,
            afterBorrow.actorDebtTokenBalance
        );
        _verifyUint(
            "actorDebtTokenBalance",
            beforeFlow.actorDebtTokenBalance - config.liquidityDepositAmount + config.borrowAmount
                - config.partialRepayAmount,
            afterFlow.actorDebtTokenBalance
        );
        _verifyUint(
            "actorCollateralTokenBalance",
            beforeFlow.actorCollateralTokenBalance - config.collateralDepositAmount,
            afterFlow.actorCollateralTokenBalance
        );
        _verifyUint(
            "poolDebtTokenBalance",
            beforeFlow.poolDebtTokenBalance + config.liquidityDepositAmount - config.borrowAmount
                + config.partialRepayAmount,
            afterFlow.poolDebtTokenBalance
        );
        _verifyUint(
            "vaultCollateralTokenBalance",
            beforeFlow.vaultCollateralTokenBalance + config.collateralDepositAmount,
            afterFlow.vaultCollateralTokenBalance
        );
        _verifyUint("debtAllowance", 0, IERC20(config.debtToken).allowance(config.demoActor, config.lendingPoolProxy));
        _verifyUint(
            "collateralAllowance",
            0,
            IERC20(config.collateralToken).allowance(config.demoActor, config.lendingPoolProxy)
        );

        _verifyWiring(config, beforeFlow);
        _verifyWiring(config, afterFlow);
    }

    function _snapshot(FlowConfig memory config) internal view returns (Snapshot memory snapshot) {
        LendingPool pool = LendingPool(config.lendingPoolProxy);
        snapshot.actorDebtTokenBalance = IERC20(config.debtToken).balanceOf(config.demoActor);
        snapshot.actorCollateralTokenBalance = IERC20(config.collateralToken).balanceOf(config.demoActor);
        snapshot.poolDebtTokenBalance = IERC20(config.debtToken).balanceOf(config.lendingPoolProxy);
        snapshot.vaultCollateralTokenBalance = IERC20(config.collateralToken).balanceOf(config.collateralVault);
        snapshot.actorLiquidityBalance = pool.liquidityBalanceOf(config.demoActor);
        snapshot.actorCollateralShares = pool.collateralSharesOf(config.demoActor);
        snapshot.actorScaledDebt = pool.scaledDebtOf(config.demoActor);
        snapshot.actorDebt = pool.debtBalanceOf(config.demoActor);
        snapshot.vault = address(pool.vault());
        snapshot.collateral = address(pool.collateralAsset());
        snapshot.debt = address(pool.debtAsset());
        snapshot.feed = address(pool.priceFeed());
        snapshot.authority = pool.upgradeAuthority();
        snapshot.pendingAuthority = pool.pendingUpgradeAuthority();
    }

    function _verifyWiring(FlowConfig memory config, Snapshot memory snapshot) internal pure {
        _verifyAddress("vault", config.collateralVault, snapshot.vault);
        _verifyAddress("collateral", config.collateralToken, snapshot.collateral);
        _verifyAddress("debt", config.debtToken, snapshot.debt);
        _verifyAddress("feed", config.priceFeed, snapshot.feed);
        _verifyAddress("upgradeAuthority", config.expectedSafeAuthority, snapshot.authority);
        _verifyAddress("pendingUpgradeAuthority", address(0), snapshot.pendingAuthority);
    }

    function _readFlowConfig() internal view returns (FlowConfig memory config) {
        config = FlowConfig({
            expectedChainId: vm.envUint("EXPECTED_CHAIN_ID"),
            lendingPoolProxy: vm.envAddress("LENDING_POOL_PROXY"),
            collateralVault: vm.envAddress("COLLATERAL_VAULT"),
            collateralToken: vm.envAddress("COLLATERAL_TOKEN"),
            debtToken: vm.envAddress("DEBT_TOKEN"),
            priceFeed: vm.envAddress("PRICE_FEED"),
            expectedSafeAuthority: vm.envAddress("EXPECTED_SAFE_AUTHORITY"),
            demoActor: vm.envAddress("DEMO_ACTOR"),
            liquidityDepositAmount: vm.envUint("LIQUIDITY_DEPOSIT_AMOUNT"),
            collateralDepositAmount: vm.envUint("COLLATERAL_DEPOSIT_AMOUNT"),
            borrowAmount: vm.envUint("BORROW_AMOUNT"),
            partialRepayAmount: vm.envUint("PARTIAL_REPAY_AMOUNT")
        });
    }

    function _validateAddress(bytes32 field, address account) internal view {
        if (account == address(0)) revert InvalidAddress(field, account);
        if (account.code.length == 0) revert AddressHasNoCode(field, account);
    }

    function _checkAddress(bytes32 field, address expectedAddress, address actualAddress) internal pure {
        if (actualAddress != expectedAddress) revert ConfigurationMismatch(field, expectedAddress, actualAddress);
    }

    function _verifyUint(bytes32 field, uint256 expectedValue, uint256 actualValue) internal pure {
        if (expectedValue != actualValue) revert PostFlowVerificationFailed(field, expectedValue, actualValue);
    }

    function _verifyAddress(bytes32 field, address expectedAddress, address actualAddress) internal pure {
        if (expectedAddress != actualAddress) {
            revert PostFlowAddressVerificationFailed(field, expectedAddress, actualAddress);
        }
    }

    function _logResult(FlowConfig memory config, FlowResult memory result) internal view {
        console2.log("Chain ID:", block.chainid);
        console2.log("Demo actor:", config.demoActor);
        console2.log("LendingPool proxy:", config.lendingPoolProxy);
        console2.log("CollateralVault:", config.collateralVault);
        console2.log("Collateral token:", config.collateralToken);
        console2.log("Debt token:", config.debtToken);
        console2.log("Price feed:", config.priceFeed);
        console2.log("Safe authority:", config.expectedSafeAuthority);
        console2.log("Liquidity / collateral / borrow / repay:");
        console2.log(
            config.liquidityDepositAmount,
            config.collateralDepositAmount,
            config.borrowAmount,
            config.partialRepayAmount
        );
        console2.log("Debt balance before / after borrow / after repay:");
        console2.log(
            result.beforeFlow.actorDebtTokenBalance,
            result.afterBorrow.actorDebtTokenBalance,
            result.afterFlow.actorDebtTokenBalance
        );
        console2.log(
            "Liquidity before / after:", result.beforeFlow.actorLiquidityBalance, result.afterFlow.actorLiquidityBalance
        );
        console2.log(
            "Collateral shares before / after:",
            result.beforeFlow.actorCollateralShares,
            result.afterFlow.actorCollateralShares
        );
        console2.log(
            "Scaled debt after borrow / after repay:",
            result.afterBorrow.actorScaledDebt,
            result.afterFlow.actorScaledDebt
        );
    }
}
