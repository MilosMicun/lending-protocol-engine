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
    address public oracle;
    IERC20 public asset;

    uint256 public totalDebt;
    uint256 public totalCollateral;

    mapping(address => uint256) public debtBalanceOf;
    mapping(address => uint256) public collateralBalanceOf;

    error ZeroAddress();
    error InvalidRiskParameters();
    error ZeroAmount();
    error AssetMismatch();
    error InsufficientCollateral();
    error OutstandingDebt();

    event Deposited(address indexed user, uint256 amount, uint256 shares);
    event Withdrawn(address indexed user, uint256 amount, uint256 shares);

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
            ltvBps_ == 0 || liquidationThresholdBps_ == 0 || liquidationBonusBps_ == 0 || ltvBps_ >= liquidationThresholdBps_
                || liquidationThresholdBps_ > 10_000 || liquidationBonusBps_ > 10_000
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

        collateralBalanceOf[msg.sender] += amount;
        totalCollateral += amount;

        emit Deposited(msg.sender, amount, shares);
    }

    function withdrawCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        uint256 collateral = collateralBalanceOf[msg.sender];
        if (collateral < amount ) revert InsufficientCollateral();

        uint256 debt = debtBalanceOf[msg.sender];
        // TODO: replace this with a health factor check once borrow logic and oracle are implemented.
        // Current behavior blocks all withdrawals if any debt exists, which is overly restrictive.
        if (debt != 0) revert OutstandingDebt();

        collateralBalanceOf[msg.sender] -= amount;
        totalCollateral -= amount;

        uint256 shares = vault.withdraw(amount, address(this), address(this));
        asset.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, shares);


    }
}
