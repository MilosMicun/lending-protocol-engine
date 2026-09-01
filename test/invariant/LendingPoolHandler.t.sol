// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

import {LendingPool} from "../../src/core/lending/LendingPool.sol";
import {CollateralVault} from "../../src/core/vault/CollateralVault.sol";

// NOTE: Through the real proxy, this invariant handler covers liquidity and collateral deposits,
// borrow/repay, liquidation, liquidity and collateral withdrawals, and multiple LP actors.
contract LendingPoolHandler is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MINIMUM_COLLATERAL = 100 ether;

    LendingPool public pool;
    MockERC20 public asset;
    MockV3Aggregator public priceFeed;

    address[] public users;

    uint256 public attemptedBorrowCalls;
    uint256 public successfulBorrowCalls;
    uint256 public expectedRejectedBorrowCalls;
    uint256 public attemptedLiquidationCalls;
    uint256 public successfulLiquidationCalls;
    uint256 public expectedRejectedLiquidationCalls;
    uint256 public attemptedExternalLiquidityDepositCalls;
    uint256 public successfulExternalLiquidityDepositCalls;
    uint256 public distinctLiquidityProviders;
    uint256 public attemptedLiquidityWithdrawalCalls;
    uint256 public successfulLiquidityWithdrawalCalls;
    uint256 public attemptedCollateralWithdrawalCalls;
    uint256 public successfulCollateralWithdrawalCalls;

    mapping(address => bool) public successfulLiquidityProvider;

    int256 internal immutable REFERENCE_PRICE;
    uint256 internal immutable REFERENCE_PRICE_WAD;
    address internal lastBorrower;

    constructor(LendingPool poolProxy_, MockERC20 asset_, MockV3Aggregator priceFeed_, address[] memory users_) {
        pool = poolProxy_;
        asset = asset_;
        priceFeed = priceFeed_;

        (, int256 answer,,,) = priceFeed_.latestRoundData();
        REFERENCE_PRICE = answer;
        // The invariant fixture constructs the mock with a positive, eight-decimal answer.
        // forge-lint: disable-next-line(unsafe-typecast)
        REFERENCE_PRICE_WAD = uint256(answer) * 10 ** (18 - priceFeed_.decimals());

        for (uint256 i = 0; i < users_.length; i++) {
            users.push(users_[i]);
        }
    }

    function userCount() external view returns (uint256) {
        return users.length;
    }

    function depositLiquidity(uint256 providerSeed, uint256 amount) external {
        address provider = _getLiquidityProvider(providerSeed);

        amount = bound(amount, 1, 1_000 ether);

        asset.mint(provider, amount);

        vm.startPrank(provider);
        asset.approve(address(pool), amount);
        attemptedExternalLiquidityDepositCalls++;
        pool.depositLiquidity(amount);
        successfulExternalLiquidityDepositCalls++;
        vm.stopPrank();

        if (!successfulLiquidityProvider[provider]) {
            successfulLiquidityProvider[provider] = true;
            distinctLiquidityProviders++;
        }
    }

    function depositCollateral(uint256 userSeed, uint256 amount) external {
        address user = _getUser(userSeed);

        amount = bound(amount, 1, 1_000 ether);

        asset.mint(user, amount);

        vm.startPrank(user);
        asset.approve(address(pool), amount);
        pool.depositCollateral(amount);
        vm.stopPrank();
    }

    function borrow(uint256 userSeed, uint256 amount) external {
        address user = _getUser(userSeed);

        _setReferencePrice();
        _ensureBorrowCapacity(user);

        uint256 maxBorrow = pool.maxBorrowOf(user);
        uint256 debt = pool.debtBalanceOf(user);
        uint256 remainingBorrowCapacity = maxBorrow - debt;
        _ensureAvailableLiquidity(remainingBorrowCapacity);

        uint256 lowerBound = (remainingBorrowCapacity + 1) / 2;
        amount = bound(amount, lowerBound, remainingBorrowCapacity);

        attemptedBorrowCalls++;
        vm.prank(user);
        // The immediately preceding bounds make every protocol rejection unexpected.
        pool.borrow(amount);
        successfulBorrowCalls++;
        lastBorrower = user;
    }

    function repay(uint256 userSeed, uint256 amount) external {
        address user = _getUser(userSeed);

        uint256 debt = pool.debtBalanceOf(user);
        if (debt == 0) return;

        amount = bound(amount, 1, debt);

        asset.mint(user, amount);

        vm.startPrank(user);
        asset.approve(address(pool), amount);
        pool.repay(amount);
        vm.stopPrank();
    }

    function withdrawLiquidity(uint256 providerSeed, uint256 amount) external {
        address provider = _getLiquidityProviderWithBalance(providerSeed);
        if (provider == address(0)) return;

        uint256 safeUpperBound = pool.liquidityBalanceOf(provider);
        uint256 available = pool.availableLiquidity();
        uint256 proxyBalance = asset.balanceOf(address(pool));

        if (available < safeUpperBound) safeUpperBound = available;
        if (proxyBalance < safeUpperBound) safeUpperBound = proxyBalance;
        if (safeUpperBound == 0) return;

        amount = bound(amount, 1, safeUpperBound);

        uint256 providerLiquidityBefore = pool.liquidityBalanceOf(provider);
        uint256 totalLiquidityBefore = pool.totalLiquidity();
        uint256 providerBalanceBefore = asset.balanceOf(provider);
        uint256 proxyBalanceBefore = asset.balanceOf(address(pool));

        vm.startPrank(provider);
        attemptedLiquidityWithdrawalCalls++;
        pool.withdrawLiquidity(amount);
        successfulLiquidityWithdrawalCalls++;
        vm.stopPrank();

        assertEq(pool.liquidityBalanceOf(provider), providerLiquidityBefore - amount);
        assertEq(pool.totalLiquidity(), totalLiquidityBefore - amount);
        assertEq(asset.balanceOf(provider), providerBalanceBefore + amount);
        assertEq(asset.balanceOf(address(pool)), proxyBalanceBefore - amount);
    }

    function withdrawCollateral(uint256 userSeed, uint256 amount) external {
        _setReferencePrice();

        (address user, uint256 safeUpperBound) = _getUserWithWithdrawableCollateral(userSeed);
        if (user == address(0)) return;

        amount = bound(amount, 1, safeUpperBound);

        CollateralVault collateralVault = pool.vault();
        uint256 userCollateralAssetsBefore = pool.getCollateralAssets(user);
        uint256 userCollateralSharesBefore = pool.collateralSharesOf(user);
        uint256 totalCollateralSharesBefore = pool.totalCollateralShares();
        uint256 userBalanceBefore = asset.balanceOf(user);
        uint256 vaultAssetsBefore = collateralVault.totalAssets();
        uint256 vaultSupplyBefore = collateralVault.totalSupply();
        uint256 sharesConsumed = collateralVault.previewWithdraw(amount);

        assertLe(sharesConsumed, userCollateralSharesBefore);
        assertLe(amount, userCollateralAssetsBefore);

        vm.startPrank(user);
        attemptedCollateralWithdrawalCalls++;
        pool.withdrawCollateral(amount);
        successfulCollateralWithdrawalCalls++;
        vm.stopPrank();

        assertEq(pool.collateralSharesOf(user), userCollateralSharesBefore - sharesConsumed);
        assertEq(pool.totalCollateralShares(), totalCollateralSharesBefore - sharesConsumed);
        assertEq(asset.balanceOf(user), userBalanceBefore + amount);
        assertEq(collateralVault.totalAssets(), vaultAssetsBefore - amount);
        assertEq(collateralVault.totalSupply(), vaultSupplyBefore - sharesConsumed);

        if (pool.debtBalanceOf(user) != 0) {
            assertGe(pool.getHealthFactor(user), WAD);
        }
    }

    function liquidate(uint256 borrowerSeed, uint256 repayAmount) external {
        // The smallest valid oracle answer makes a bounded, debt-backed handler position unhealthy.
        priceFeed.setAnswer(1);

        address borrower = _getLiquidatableBorrower(borrowerSeed);
        if (borrower == address(0)) return;

        uint256 debt = pool.debtBalanceOf(borrower);

        repayAmount = bound(repayAmount, 1, debt);

        asset.mint(address(this), repayAmount);
        asset.approve(address(pool), repayAmount);

        attemptedLiquidationCalls++;
        // Debt, unhealthy health factor, balance, and allowance are fixed immediately before this call.
        try pool.liquidate(borrower, repayAmount) {
            successfulLiquidationCalls++;
        } catch (bytes memory reason) {
            bytes4 selector = _selectorOrRevert(reason);

            // BadDebt() has no arguments, so its canonical payload is exactly the four-byte selector.
            // Collateral worth one wei cannot cover a positive repayment after the liquidation bonus.
            if (selector == LendingPool.BadDebt.selector && reason.length == 4) {
                expectedRejectedLiquidationCalls++;
                return;
            }

            _revert(reason);
        }
    }

    function warpTime(uint256 timeElapsed) external {
        timeElapsed = bound(timeElapsed, 1, 30 days);

        vm.warp(block.timestamp + timeElapsed);
        priceFeed.setUpdatedAt(block.timestamp);
    }

    function _getUser(uint256 seed) internal view returns (address) {
        return users[seed % users.length];
    }

    function _getLiquidityProvider(uint256 seed) internal view returns (address) {
        uint256 start = seed % users.length;

        if (distinctLiquidityProviders < users.length) {
            for (uint256 i = 0; i < users.length; i++) {
                address provider = users[(start + i) % users.length];
                if (!successfulLiquidityProvider[provider]) return provider;
            }
        }

        return users[start];
    }

    function _getLiquidityProviderWithBalance(uint256 seed) internal view returns (address) {
        uint256 start = seed % users.length;

        for (uint256 i = 0; i < users.length; i++) {
            address provider = users[(start + i) % users.length];
            if (pool.liquidityBalanceOf(provider) != 0) return provider;
        }

        return address(0);
    }

    function _getUserWithWithdrawableCollateral(uint256 seed) internal view returns (address, uint256) {
        uint256 start = seed % users.length;

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[(start + i) % users.length];
            uint256 safeUpperBound = _safeCollateralWithdrawalBound(user);
            if (safeUpperBound != 0) return (user, safeUpperBound);
        }

        return (address(0), 0);
    }

    function _safeCollateralWithdrawalBound(address user) internal view returns (uint256) {
        uint256 userShares = pool.collateralSharesOf(user);
        if (userShares == 0) return 0;

        CollateralVault collateralVault = pool.vault();
        uint256 userAssets = pool.getCollateralAssets(user);
        if (userAssets == 0) return 0;

        uint256 safeUpperBound = userAssets;
        uint256 vaultMaximum = collateralVault.maxWithdraw(address(pool));
        if (vaultMaximum < safeUpperBound) safeUpperBound = vaultMaximum;

        uint256 debt = pool.debtBalanceOf(user);
        if (debt != 0) {
            uint256 minimumCollateralValue = _ceilDiv(debt * BPS, pool.liquidationThresholdBps());
            uint256 minimumCollateralAssets = _ceilDiv(minimumCollateralValue * WAD, REFERENCE_PRICE_WAD);

            // Retain one asset unit beyond the exact inverse of the production health-factor floors.
            if (userAssets <= minimumCollateralAssets + 1) return 0;

            uint256 healthBound = userAssets - minimumCollateralAssets - 1;
            if (healthBound < safeUpperBound) safeUpperBound = healthBound;
        }

        return _capToPreviewWithdrawShares(collateralVault, userShares, safeUpperBound);
    }

    function _capToPreviewWithdrawShares(CollateralVault collateralVault, uint256 userShares, uint256 upperBound)
        internal
        view
        returns (uint256)
    {
        if (collateralVault.previewWithdraw(upperBound) <= userShares) return upperBound;

        uint256 lowerBound;
        while (lowerBound < upperBound) {
            uint256 midpoint = lowerBound + (upperBound - lowerBound + 1) / 2;

            if (collateralVault.previewWithdraw(midpoint) <= userShares) {
                lowerBound = midpoint;
            } else {
                upperBound = midpoint - 1;
            }
        }

        return lowerBound;
    }

    function _getLiquidatableBorrower(uint256 seed) internal view returns (address) {
        if (lastBorrower != address(0) && _hasLiquidatableDebtBackedCollateral(lastBorrower)) {
            return lastBorrower;
        }

        uint256 start = seed % users.length;
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[(start + i) % users.length];
            if (_hasLiquidatableDebtBackedCollateral(user)) return user;
        }

        return address(0);
    }

    function _hasLiquidatableDebtBackedCollateral(address user) internal view returns (bool) {
        return pool.getCollateralAssets(user) >= 1e8 && pool.isLiquidatable(user);
    }

    function _ensureBorrowCapacity(address user) internal {
        uint256 collateralAssets = pool.getCollateralAssets(user);
        if (collateralAssets < MINIMUM_COLLATERAL) {
            _depositCollateral(user, MINIMUM_COLLATERAL - collateralAssets);
        }

        uint256 debt = pool.debtBalanceOf(user);
        uint256 maxBorrow = pool.maxBorrowOf(user);
        if (maxBorrow > debt) return;

        uint256 targetCollateralValue = _ceilDiv((debt + 1) * BPS, pool.ltvBps());
        uint256 currentCollateralValue = pool.getCollateralValue(user);
        uint256 additionalCollateralValue = targetCollateralValue - currentCollateralValue;
        uint256 additionalCollateralAssets = _ceilDiv(additionalCollateralValue * WAD, REFERENCE_PRICE_WAD);

        _depositCollateral(user, additionalCollateralAssets);
    }

    function _ensureAvailableLiquidity(uint256 required) internal {
        uint256 totalDebt = pool.totalDebt();
        uint256 totalLiquidity = pool.totalLiquidity();
        uint256 balance = asset.balanceOf(address(pool));

        uint256 accountingShortfall;
        if (totalLiquidity >= totalDebt) {
            uint256 available = totalLiquidity - totalDebt;
            accountingShortfall = available < required ? required - available : 0;
        } else {
            accountingShortfall = totalDebt - totalLiquidity + required;
        }

        uint256 balanceShortfall = balance < required ? required - balance : 0;
        uint256 amount = accountingShortfall > balanceShortfall ? accountingShortfall : balanceShortfall;
        if (amount == 0) return;

        asset.mint(address(this), amount);
        asset.approve(address(pool), amount);
        pool.depositLiquidity(amount);
    }

    function _depositCollateral(address user, uint256 amount) internal {
        asset.mint(user, amount);

        vm.startPrank(user);
        asset.approve(address(pool), amount);
        pool.depositCollateral(amount);
        vm.stopPrank();
    }

    function _setReferencePrice() internal {
        priceFeed.setAnswer(REFERENCE_PRICE);
        priceFeed.setUpdatedAt(block.timestamp);
    }

    function _ceilDiv(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (numerator == 0) return 0;
        return (numerator - 1) / denominator + 1;
    }

    function _selectorOrRevert(bytes memory reason) internal pure returns (bytes4 selector) {
        if (reason.length < 4) _revert(reason);

        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }
    }

    function _revert(bytes memory reason) internal pure {
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }
}
