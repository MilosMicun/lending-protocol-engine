// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CollateralVault} from "../vault/CollateralVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract LendingPool {
    using SafeERC20 for IERC20;

    uint256 public ltvBps;
    uint256 public liquidationThresholdBps;
    uint256 public liquidationBonusBps;

    CollateralVault public vault;
    // Oracle is accepted now but integrated in Day 85 for collateral valuation.
    address public oracle;
    IERC20 public asset;

    uint256 public totalDebt;
    uint256 public totalCollateralShares;
    uint256 public totalLiquidity;

    mapping(address => uint256) public debtBalanceOf;
    mapping(address => uint256) public collateralSharesOf;
    mapping(address => uint256) public liquidityBalanceOf;

    error ZeroAddress();
    error InvalidRiskParameters();
    error ZeroAmount();
    error AssetMismatch();
    error InsufficientCollateral();
    error OutstandingDebt();
    error InsufficientLiquidity();
    error BorrowExceedsLimit();
    error NoDebt();

    event Deposited(address indexed user, uint256 amount, uint256 shares);
    event Withdrawn(address indexed user, uint256 amount, uint256 shares);
    event LiquidityDeposited(address indexed user, uint256 amount);
    event LiquidityWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 newDebt);
    event Repaid(address indexed user, uint256 amount, uint256 newDebt);

    constructor(
        address oracle_,
        address vault_,
        address asset_,
        uint256 ltvBps_,
        uint256 liquidationThresholdBps_,
        uint256 liquidationBonusBps_
    ) {
        if (oracle_ == address(0) || vault_ == address(0) || asset_ == address(0)) {
            revert ZeroAddress();
        }

        oracle = oracle_;
        vault = CollateralVault(vault_);
        asset = IERC20(asset_);

        if (vault.asset() != asset_) {
            revert AssetMismatch();
        }

        if (
            ltvBps_ == 0 || liquidationThresholdBps_ == 0 || liquidationBonusBps_ == 0
                || ltvBps_ >= liquidationThresholdBps_ || liquidationThresholdBps_ > 10_000
                || liquidationBonusBps_ > 10_000
        ) {
            revert InvalidRiskParameters();
        }

        ltvBps = ltvBps_;
        liquidationThresholdBps = liquidationThresholdBps_;
        liquidationBonusBps = liquidationBonusBps_;
    }

    function depositCollateral(uint256 amount) external {
        if (amount == 0) {
            revert ZeroAmount();
        }

        asset.safeTransferFrom(msg.sender, address(this), amount);
        asset.forceApprove(address(vault), amount);

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

        uint256 debt = debtBalanceOf[msg.sender];
        // TODO: replace this with a health factor check once borrow logic and oracle are implemented.
        // Current behavior blocks all withdrawals if any debt exists, which is overly restrictive.
        if (debt != 0) revert OutstandingDebt();

        uint256 shares = vault.withdraw(amount, address(this), address(this));

        collateralSharesOf[msg.sender] -= shares;
        totalCollateralShares -= shares;

        asset.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, shares);
    }

    function depositLiquidity(uint256 amount) external {
        if (amount == 0) {
            revert ZeroAmount();
        }

        asset.safeTransferFrom(msg.sender, address(this), amount);

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

        asset.safeTransfer(msg.sender, amount);

        emit LiquidityWithdrawn(msg.sender, amount);
    }

    function availableLiquidity() public view returns (uint256) {
        return totalLiquidity - totalDebt;
    }

    function borrow(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        if (collateralSharesOf[msg.sender] == 0) revert InsufficientCollateral();

        // Until oracle integration, collateral and borrow asset are assumed to have 1:1 value.
        uint256 maxBorrow = maxBorrowOf(msg.sender);
        uint256 newDebt = debtBalanceOf[msg.sender] + amount;

        if (newDebt > maxBorrow) revert BorrowExceedsLimit();

        uint256 available = availableLiquidity();
        if (amount > available) revert InsufficientLiquidity();

        debtBalanceOf[msg.sender] = newDebt;
        totalDebt += amount;

        asset.safeTransfer(msg.sender, amount);

        emit Borrowed(msg.sender, amount, newDebt);
    }

    function getCollateralAssets(address user) public view returns (uint256) {
        return vault.convertToAssets(collateralSharesOf[user]);
    }

    function maxBorrowOf(address user) public view returns (uint256) {
        return getCollateralAssets(user) * ltvBps / 10_000;
    }

    function repay(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        uint256 debt = debtBalanceOf[msg.sender];

        if (debt == 0) revert NoDebt();

        // Cap repayment at actual debt — no revert on overpayment, excess is ignored.
        uint256 repayAmount = amount > debt ? debt : amount;

        uint256 newDebt = debt - repayAmount;

        debtBalanceOf[msg.sender] = newDebt;
        totalDebt -= repayAmount;

        asset.safeTransferFrom(msg.sender, address(this), repayAmount);

        emit Repaid(msg.sender, repayAmount, newDebt);
    }
}
