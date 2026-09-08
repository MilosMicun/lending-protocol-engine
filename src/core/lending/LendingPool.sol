// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CollateralVault} from "../vault/CollateralVault.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceFeed} from "../../interfaces/IPriceFeed.sol";
import {OracleLib} from "../../lib/OracleLib.sol";

contract LendingPool is Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:lending.protocol.storage.LendingPoolUpgradeAuthority
    struct UpgradeAuthorityStorage {
        address activeAuthority;
        address pendingAuthority;
    }

    bytes32 private constant UPGRADE_AUTHORITY_STORAGE =
        0x8000ce11f38414f298b74975bfaea500fcdbebb431834e96f66ac2883c9bb800;

    uint256 public ltvBps;
    uint256 public liquidationThresholdBps;
    uint256 public liquidationBonusBps;

    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    CollateralVault public vault;
    IPriceFeed public priceFeed;
    IERC20 public debtAsset;
    IERC20 public collateralAsset;

    uint256 public maxPriceStaleness;

    uint256 public borrowIndex;
    uint256 public lastBorrowIndexUpdate;
    uint256 public totalCollateralShares;
    uint256 public totalLiquidity;
    uint256 public baseBorrowRate;
    uint256 public borrowRateSlope;

    uint256 public totalScaledDebt;
    mapping(address => uint256) public scaledDebtOf;

    mapping(address => uint256) public collateralSharesOf;
    mapping(address => uint256) public liquidityBalanceOf;

    error ZeroAddress();
    error InvalidRiskParameters();
    error InvalidInterestRateModel();
    error InvalidStalenessWindow();
    error ZeroAmount();
    error ZeroCollateralShares();
    error InsufficientCollateral();
    error InsufficientLiquidity();
    error BorrowExceedsLimit();
    error NoDebt();
    error PositionNotLiquidatable();
    error SelfLiquidation();
    error BadDebt();
    error HealthFactorTooLow();
    error UnauthorizedUpgradeAuthority(address caller);
    error InvalidUpgradeAuthority(address authority);
    error NotPendingUpgradeAuthority(address caller);

    event Deposited(address indexed user, uint256 amount, uint256 shares);
    event Withdrawn(address indexed user, uint256 amount, uint256 shares);
    event LiquidityDeposited(address indexed user, uint256 amount);
    event LiquidityWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 newDebt);
    event Repaid(address indexed user, uint256 amount, uint256 newDebt);
    event BorrowIndexUpdated(uint256 newBorrowIndex);

    event UpgradeAuthorityTransferStarted(address indexed currentAuthority, address indexed pendingAuthority);
    event UpgradeAuthorityTransferred(address indexed previousAuthority, address indexed newAuthority);

    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        uint256 repaidAmount,
        uint256 seizedShares,
        uint256 seizedAssets
    );

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address priceFeed_,
        address vault_,
        address debtAsset_,
        uint256 maxPriceStaleness_,
        uint256 ltvBps_,
        uint256 liquidationThresholdBps_,
        uint256 liquidationBonusBps_,
        uint256 baseBorrowRate_,
        uint256 borrowRateSlope_,
        address initialUpgradeAuthority_
    ) external initializer {
        if (priceFeed_ == address(0) || vault_ == address(0) || debtAsset_ == address(0)) {
            revert ZeroAddress();
        }

        _validateDebtAsset(debtAsset_);

        if (maxPriceStaleness_ == 0) {
            revert InvalidStalenessWindow();
        }

        if (
            ltvBps_ == 0 || liquidationThresholdBps_ == 0 || liquidationBonusBps_ == 0
                || ltvBps_ >= liquidationThresholdBps_ || liquidationThresholdBps_ > BPS || liquidationBonusBps_ > BPS
        ) {
            revert InvalidRiskParameters();
        }

        if (baseBorrowRate_ + borrowRateSlope_ > WAD) {
            revert InvalidInterestRateModel();
        }

        if (initialUpgradeAuthority_ == address(0)) {
            revert InvalidUpgradeAuthority(initialUpgradeAuthority_);
        }

        priceFeed = IPriceFeed(priceFeed_);
        vault = CollateralVault(vault_);
        collateralAsset = IERC20(vault.asset());
        debtAsset = IERC20(debtAsset_);
        maxPriceStaleness = maxPriceStaleness_;

        ltvBps = ltvBps_;
        liquidationThresholdBps = liquidationThresholdBps_;
        liquidationBonusBps = liquidationBonusBps_;
        borrowIndex = WAD;
        lastBorrowIndexUpdate = block.timestamp;
        baseBorrowRate = baseBorrowRate_;
        borrowRateSlope = borrowRateSlope_;

        UpgradeAuthorityStorage storage authorityStorage = _getUpgradeAuthorityStorage();
        authorityStorage.activeAuthority = initialUpgradeAuthority_;
        authorityStorage.pendingAuthority = address(0);
    }

    function upgradeAuthority() public view returns (address) {
        return _getUpgradeAuthorityStorage().activeAuthority;
    }

    function pendingUpgradeAuthority() public view returns (address) {
        return _getUpgradeAuthorityStorage().pendingAuthority;
    }

    function proposeUpgradeAuthority(address newAuthority) external {
        UpgradeAuthorityStorage storage authorityStorage = _getUpgradeAuthorityStorage();

        if (msg.sender != authorityStorage.activeAuthority) {
            revert UnauthorizedUpgradeAuthority(msg.sender);
        }

        if (newAuthority == address(0)) {
            revert InvalidUpgradeAuthority(newAuthority);
        }

        authorityStorage.pendingAuthority = newAuthority;

        emit UpgradeAuthorityTransferStarted(authorityStorage.activeAuthority, newAuthority);
    }

    function acceptUpgradeAuthority() external {
        UpgradeAuthorityStorage storage authorityStorage = _getUpgradeAuthorityStorage();

        if (msg.sender != authorityStorage.pendingAuthority) {
            revert NotPendingUpgradeAuthority(msg.sender);
        }

        address previousAuthority = authorityStorage.activeAuthority;
        authorityStorage.activeAuthority = msg.sender;
        authorityStorage.pendingAuthority = address(0);

        emit UpgradeAuthorityTransferred(previousAuthority, msg.sender);
    }

    function debtBalanceOf(address user) public view returns (uint256) {
        return _scaledToDebt(scaledDebtOf[user], currentBorrowIndex());
    }

    function totalDebt() public view returns (uint256) {
        return _scaledToDebt(totalScaledDebt, currentBorrowIndex());
    }

    function currentBorrowIndex() public view returns (uint256) {
        uint256 timeElapsed = block.timestamp - lastBorrowIndexUpdate;

        if (timeElapsed == 0) {
            _validateAccountingDomain(borrowIndex);
            return borrowIndex;
        }

        if (totalScaledDebt == 0) {
            _validateAccountingDomain(borrowIndex);
            return borrowIndex;
        }

        uint256 accruedIndex = _accruedBorrowIndex(timeElapsed);
        _validateAccountingDomain(accruedIndex);

        return accruedIndex;
    }

    function _accruedBorrowIndex(uint256 timeElapsed) internal view virtual returns (uint256) {
        uint256 rate = currentBorrowRate();
        uint256 interestFactor = rate * timeElapsed / SECONDS_PER_YEAR;
        uint256 secondOrderTerm = interestFactor * interestFactor / (2 * WAD);

        return borrowIndex * (WAD + interestFactor + secondOrderTerm) / WAD;
    }

    function utilizationRate() public view returns (uint256) {
        if (totalLiquidity == 0) return 0;

        uint256 debt = _storedTotalDebt();

        if (debt >= totalLiquidity) {
            return WAD;
        }

        return _debtToUtilization(debt, totalLiquidity);
    }

    function currentBorrowRate() public view returns (uint256) {
        uint256 utilization = utilizationRate();

        return baseBorrowRate + _variableBorrowRate(utilization, borrowRateSlope);
    }

    function depositCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        collateralAsset.safeTransferFrom(msg.sender, address(this), amount);
        collateralAsset.forceApprove(address(vault), amount);

        uint256 shares = vault.deposit(amount, address(this));
        if (shares == 0) revert ZeroCollateralShares();

        collateralSharesOf[msg.sender] += shares;
        totalCollateralShares += shares;

        emit Deposited(msg.sender, amount, shares);
    }

    function withdrawCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        uint256 sharesNeeded = vault.previewWithdraw(amount);

        uint256 collateral = collateralSharesOf[msg.sender];
        if (collateral < sharesNeeded) revert InsufficientCollateral();

        uint256 debt = debtBalanceOf(msg.sender);

        if (debt != 0) {
            uint256 remainingShares = collateral - sharesNeeded;
            uint256 remainingCollateralAssets = vault.convertToAssets(remainingShares);
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

        _updateBorrowIndex();

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

        _updateBorrowIndex();

        liquidityBalanceOf[msg.sender] -= amount;
        totalLiquidity -= amount;

        debtAsset.safeTransfer(msg.sender, amount);

        emit LiquidityWithdrawn(msg.sender, amount);
    }

    function availableLiquidity() public view returns (uint256) {
        uint256 debt = totalDebt();

        if (debt >= totalLiquidity) {
            return 0;
        }

        return totalLiquidity - debt;
    }

    function borrow(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        _updateBorrowIndex();

        if (collateralSharesOf[msg.sender] == 0) revert InsufficientCollateral();

        (uint256 scaledAmount, uint256 newDebt) = _prepareBorrow(msg.sender, amount);

        scaledDebtOf[msg.sender] += scaledAmount;
        totalScaledDebt += scaledAmount;

        debtAsset.safeTransfer(msg.sender, amount);

        emit Borrowed(msg.sender, amount, newDebt);
    }

    function repay(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        _updateBorrowIndex();

        uint256 debt = debtBalanceOf(msg.sender);
        if (debt == 0) revert NoDebt();

        uint256 repayAmount = amount > debt ? debt : amount;
        uint256 newDebt = _applyDebtRepayment(msg.sender, debt, repayAmount);

        debtAsset.safeTransferFrom(msg.sender, address(this), repayAmount);

        emit Repaid(msg.sender, repayAmount, newDebt);
    }

    function liquidate(address borrower, uint256 repayAmount) external {
        if (borrower == address(0)) revert ZeroAddress();
        if (msg.sender == borrower) revert SelfLiquidation();
        if (repayAmount == 0) revert ZeroAmount();

        _updateBorrowIndex();

        uint256 debt = debtBalanceOf(borrower);
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

        _applyDebtRepayment(borrower, debt, actualRepay);

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
        uint256 debt = debtBalanceOf(user);

        return _healthFactor(collateralValue, debt);
    }

    function isLiquidatable(address user) public view returns (bool) {
        uint256 debt = debtBalanceOf(user);

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

    function _updateBorrowIndex() internal {
        uint256 newIndex = currentBorrowIndex();

        if (newIndex != borrowIndex) {
            borrowIndex = newIndex;
            emit BorrowIndexUpdated(newIndex);
        }

        lastBorrowIndexUpdate = block.timestamp;
    }

    function _storedTotalDebt() internal view returns (uint256) {
        return _scaledToDebt(totalScaledDebt, borrowIndex);
    }

    function _scaledToDebt(uint256 scaledAmount, uint256 index) internal pure virtual returns (uint256) {
        return scaledAmount * index / WAD;
    }

    function _debtToUtilization(uint256 debt, uint256 liquidity) internal pure virtual returns (uint256) {
        return debt * WAD / liquidity;
    }

    function _variableBorrowRate(uint256 utilization, uint256 slope) internal pure virtual returns (uint256) {
        return utilization * slope / WAD;
    }

    function _prepareBorrow(address user, uint256 amount)
        internal
        view
        returns (uint256 scaledAmount, uint256 newDebt)
    {
        uint256 maxBorrow = maxBorrowOf(user);
        uint256 requestedPostBorrowDebt = debtBalanceOf(user) + amount;

        if (requestedPostBorrowDebt > maxBorrow) revert BorrowExceedsLimit();

        uint256 available = availableLiquidity();
        if (amount > available) revert InsufficientLiquidity();

        scaledAmount = _scaledAmountForBorrow(amount, borrowIndex);
        _validateAccountingDomain(borrowIndex);

        uint256 normalizedPostBorrowDebt =
            _scaledToDebtForBorrowAdmission(scaledDebtOf[user] + scaledAmount, borrowIndex);
        if (normalizedPostBorrowDebt > maxBorrow) revert BorrowExceedsLimit();

        uint256 normalizedPostBorrowTotalDebt =
            _scaledToDebtForBorrowAdmission(totalScaledDebt + scaledAmount, borrowIndex);
        if (normalizedPostBorrowTotalDebt > totalLiquidity) revert InsufficientLiquidity();

        newDebt =
            requestedPostBorrowDebt > normalizedPostBorrowDebt ? requestedPostBorrowDebt : normalizedPostBorrowDebt;
    }

    function _applyDebtRepayment(address user, uint256 displayedDebt, uint256 repayment)
        internal
        returns (uint256 newDebt)
    {
        uint256 userScaledDebt = scaledDebtOf[user];

        if (repayment == displayedDebt) {
            scaledDebtOf[user] = 0;
            totalScaledDebt -= userScaledDebt;
            return 0;
        } else {
            uint256 scaledRepayAmount = _scaledAmountForPartialRepayment(repayment, borrowIndex);

            scaledDebtOf[user] -= scaledRepayAmount;
            totalScaledDebt -= scaledRepayAmount;
        }

        return _reportedDebtAfterPartialRepayment(user, displayedDebt, repayment);
    }

    function _scaledAmountForBorrow(uint256 amount, uint256 index) internal pure virtual returns (uint256) {
        return amount * WAD / index;
    }

    function _scaledToDebtForBorrowAdmission(uint256 scaledAmount, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(scaledAmount, index, WAD, Math.Rounding.Floor);
    }

    function _scaledAmountForPartialRepayment(uint256 repayment, uint256 index)
        internal
        pure
        virtual
        returns (uint256)
    {
        return repayment * WAD / index;
    }

    function _reportedDebtAfterPartialRepayment(address, uint256 displayedDebt, uint256 repayment)
        internal
        view
        virtual
        returns (uint256)
    {
        return displayedDebt - repayment;
    }

    function _validateDebtAsset(address) internal view virtual {}

    function _validateAccountingDomain(uint256) internal pure virtual {
        // V1 and V1.1 intentionally retain their unrestricted historical arithmetic domain.
    }

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != upgradeAuthority()) {
            revert UnauthorizedUpgradeAuthority(msg.sender);
        }
    }

    function _getUpgradeAuthorityStorage() private pure returns (UpgradeAuthorityStorage storage authorityStorage) {
        bytes32 slot = UPGRADE_AUTHORITY_STORAGE;

        assembly ("memory-safe") {
            authorityStorage.slot := slot
        }
    }
}
