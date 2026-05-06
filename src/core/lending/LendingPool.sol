// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CollateralVault} from "../vault/CollateralVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPriceFeed} from "../../interfaces/IPriceFeed.sol";
import {OracleLib} from "../../lib/OracleLib.sol";

contract LendingPool {
    using SafeERC20 for IERC20;

    uint256 public ltvBps;
    uint256 public liquidationThresholdBps;
    uint256 public liquidationBonusBps;

    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;

    CollateralVault public vault;
    IPriceFeed public priceFeed;
    IERC20 public debtAsset;
    IERC20 public collateralAsset;

    uint256 public maxPriceStaleness;

    uint256 public totalDebt;
    uint256 public totalCollateralShares;
    uint256 public totalLiquidity;

    mapping(address => uint256) public debtBalanceOf;
    mapping(address => uint256) public collateralSharesOf;
    mapping(address => uint256) public liquidityBalanceOf;

    error ZeroAddress();
    error InvalidRiskParameters();
    error ZeroAmount();
    error InsufficientCollateral();
    error InsufficientLiquidity();
    error BorrowExceedsLimit();
    error NoDebt();
    error PositionNotLiquidatable();
    error SelfLiquidation();
    error BadDebt();
    error HealthFactorTooLow();
    error InvalidStalenessWindow();

    event Deposited(address indexed user, uint256 amount, uint256 shares);
    event Withdrawn(address indexed user, uint256 amount, uint256 shares);
    event LiquidityDeposited(address indexed user, uint256 amount);
    event LiquidityWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 newDebt);
    event Repaid(address indexed user, uint256 amount, uint256 newDebt);

    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        uint256 repaidAmount,
        uint256 seizedShares,
        uint256 seizedAssets
    );

    constructor(
        address priceFeed_,
        address vault_,
        address debtAsset_,
        uint256 maxPriceStaleness_,
        uint256 ltvBps_,
        uint256 liquidationThresholdBps_,
        uint256 liquidationBonusBps_
    ) {
        if (priceFeed_ == address(0) || vault_ == address(0) || debtAsset_ == address(0)) {
            revert ZeroAddress();
        }

        if (maxPriceStaleness_ == 0) {
            revert InvalidStalenessWindow();
        }

        if (
            ltvBps_ == 0 || liquidationThresholdBps_ == 0 || liquidationBonusBps_ == 0
                || ltvBps_ >= liquidationThresholdBps_ || liquidationThresholdBps_ > BPS || liquidationBonusBps_ > BPS
        ) {
            revert InvalidRiskParameters();
        }

        priceFeed = IPriceFeed(priceFeed_);
        vault = CollateralVault(vault_);
        collateralAsset = IERC20(vault.asset());
        debtAsset = IERC20(debtAsset_);
        maxPriceStaleness = maxPriceStaleness_;

        ltvBps = ltvBps_;
        liquidationThresholdBps = liquidationThresholdBps_;
        liquidationBonusBps = liquidationBonusBps_;
    }

    function depositCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        collateralAsset.safeTransferFrom(msg.sender, address(this), amount);
        collateralAsset.forceApprove(address(vault), amount);

        uint256 shares = vault.deposit(amount, address(this));

        collateralSharesOf[msg.sender] += shares;
        totalCollateralShares += shares;

        emit Deposited(msg.sender, amount, shares);
    }

    function withdrawCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        uint256 sharesNeeded = vault.previewWithdraw(amount);

        uint256 collateral = collateralSharesOf[msg.sender];
        if (collateral < sharesNeeded) revert InsufficientCollateral();

        uint256 remainingCollateralAssets = getCollateralAssets(msg.sender) - amount;
        uint256 debt = debtBalanceOf[msg.sender];

        if (debt != 0) {
            uint256 priceWad = OracleLib.getFreshPriceWad(priceFeed, maxPriceStaleness);
            uint256 remainingCollateralValue = remainingCollateralAssets * priceWad / WAD;

            if (_healthFactor(remainingCollateralValue, debt) < WAD) {
                revert HealthFactorTooLow();
            }
        }

        uint256 shares = vault.withdraw(amount, address(this), address(this));

        collateralSharesOf[msg.sender] -= shares;
        totalCollateralShares -= shares;

        collateralAsset.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, shares);
    }

    function depositLiquidity(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        debtAsset.safeTransferFrom(msg.sender, address(this), amount);

        liquidityBalanceOf[msg.sender] += amount;
        totalLiquidity += amount;

        emit LiquidityDeposited(msg.sender, amount);
    }

    function withdrawLiquidity(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        uint256 balance = liquidityBalanceOf[msg.sender];
        if (balance < amount) revert InsufficientLiquidity();

        uint256 available = availableLiquidity();
        if (amount > available) revert InsufficientLiquidity();

        liquidityBalanceOf[msg.sender] -= amount;
        totalLiquidity -= amount;

        debtAsset.safeTransfer(msg.sender, amount);

        emit LiquidityWithdrawn(msg.sender, amount);
    }

    function availableLiquidity() public view returns (uint256) {
        return totalLiquidity - totalDebt;
    }

    function borrow(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        if (collateralSharesOf[msg.sender] == 0) revert InsufficientCollateral();

        uint256 maxBorrow = maxBorrowOf(msg.sender);
        uint256 newDebt = debtBalanceOf[msg.sender] + amount;

        if (newDebt > maxBorrow) revert BorrowExceedsLimit();

        uint256 available = availableLiquidity();
        if (amount > available) revert InsufficientLiquidity();

        debtBalanceOf[msg.sender] = newDebt;
        totalDebt += amount;

        debtAsset.safeTransfer(msg.sender, amount);

        emit Borrowed(msg.sender, amount, newDebt);
    }

    function repay(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        uint256 debt = debtBalanceOf[msg.sender];
        if (debt == 0) revert NoDebt();

        uint256 repayAmount = amount > debt ? debt : amount;
        uint256 newDebt = debt - repayAmount;

        debtBalanceOf[msg.sender] = newDebt;
        totalDebt -= repayAmount;

        debtAsset.safeTransferFrom(msg.sender, address(this), repayAmount);

        emit Repaid(msg.sender, repayAmount, newDebt);
    }

    function liquidate(address borrower, uint256 repayAmount) external {
        if (borrower == address(0)) revert ZeroAddress();
        if (msg.sender == borrower) revert SelfLiquidation();
        if (repayAmount == 0) revert ZeroAmount();

        uint256 debt = debtBalanceOf[borrower];
        if (debt == 0) revert NoDebt();

        uint256 priceWad = OracleLib.getFreshPriceWad(priceFeed, maxPriceStaleness);

        uint256 borrowerCollateralAssets = getCollateralAssets(borrower);
        uint256 collateralValue = borrowerCollateralAssets * priceWad / WAD;

        if (_healthFactor(collateralValue, debt) >= WAD) {
            revert PositionNotLiquidatable();
        }

        uint256 desiredRepay = repayAmount > debt ? debt : repayAmount;
        uint256 actualRepay = desiredRepay;

        uint256 repayValueWithBonus = actualRepay * (BPS + liquidationBonusBps) / BPS;
        uint256 collateralToSeizeAssets = _collateralAssetsForDebtValue(repayValueWithBonus, priceWad);

        if (collateralToSeizeAssets > borrowerCollateralAssets) {
            collateralToSeizeAssets = borrowerCollateralAssets;

            actualRepay = collateralValue * BPS / (BPS + liquidationBonusBps);

            if (actualRepay > desiredRepay) {
                actualRepay = desiredRepay;
            }

            if (actualRepay == 0) revert BadDebt();
        }

        uint256 seizedShares = vault.previewWithdraw(collateralToSeizeAssets);

        debtBalanceOf[borrower] -= actualRepay;
        totalDebt -= actualRepay;

        collateralSharesOf[borrower] -= seizedShares;
        totalCollateralShares -= seizedShares;

        debtAsset.safeTransferFrom(msg.sender, address(this), actualRepay);

        uint256 assetsOut = vault.redeem(seizedShares, msg.sender, address(this));

        emit Liquidated(msg.sender, borrower, actualRepay, seizedShares, assetsOut);
    }

    function getCollateralAssets(address user) public view returns (uint256) {
        return vault.convertToAssets(collateralSharesOf[user]);
    }

    function getCollateralValue(address user) public view returns (uint256) {
        uint256 collateralAssets = getCollateralAssets(user);
        uint256 priceWad = OracleLib.getFreshPriceWad(priceFeed, maxPriceStaleness);

        return collateralAssets * priceWad / WAD;
    }

    function maxBorrowOf(address user) public view returns (uint256) {
        return getCollateralValue(user) * ltvBps / BPS;
    }

    function getHealthFactor(address user) public view returns (uint256) {
        uint256 collateralValue = getCollateralValue(user);
        uint256 debt = debtBalanceOf[user];

        return _healthFactor(collateralValue, debt);
    }

    function isLiquidatable(address user) public view returns (bool) {
        uint256 debt = debtBalanceOf[user];

        if (debt == 0) return false;

        return getHealthFactor(user) < WAD;
    }

    function _healthFactor(uint256 collateralValue, uint256 debt) internal view returns (uint256) {
        if (debt == 0) return type(uint256).max;

        uint256 adjustedCollateralValue = collateralValue * liquidationThresholdBps / BPS;

        return adjustedCollateralValue * WAD / debt;
    }

    function _collateralAssetsForDebtValue(uint256 debtValue, uint256 priceWad) internal pure returns (uint256) {
        return debtValue * WAD / priceWad;
    }
}
