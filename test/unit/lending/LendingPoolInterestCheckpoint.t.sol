// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {LendingPoolProxyFixture} from "../../helpers/LendingPoolProxyFixture.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";

import {LendingPool} from "../../../src/core/lending/LendingPool.sol";
import {LendingPoolV1_1} from "../../../src/core/lending/LendingPoolV1_1.sol";
import {CollateralVault} from "../../../src/core/vault/CollateralVault.sol";

contract LendingPoolInterestCheckpointTest is Test, LendingPoolProxyFixture {
    event LiquidityDeposited(address indexed user, uint256 amount);
    event LiquidityWithdrawn(address indexed user, uint256 amount);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;

    MockERC20 internal asset;
    CollateralVault internal vault;
    MockV3Aggregator internal priceFeed;
    LendingPool internal pool;

    address internal borrowerOne;
    address internal borrowerTwo;
    address internal providerOne;
    address internal providerTwo;

    function setUp() public {
        borrowerOne = makeAddr("borrowerOne");
        borrowerTwo = makeAddr("borrowerTwo");
        providerOne = makeAddr("providerOne");
        providerTwo = makeAddr("providerTwo");

        asset = new MockERC20("Asset Token", "ASS");
        vault = new CollateralVault("Vault Share", "VSS", asset);
        priceFeed = new MockV3Aggregator(8, 1e8, block.timestamp);

        LendingPoolV1_1 implementation = new LendingPoolV1_1();
        pool = _deployLendingPoolProxy(
            implementation,
            LendingPoolProxyConfig({
                priceFeed: address(priceFeed),
                vault: address(vault),
                debtAsset: address(asset),
                maxPriceStaleness: 1 days,
                ltvBps: 7_000,
                liquidationThresholdBps: 8_000,
                liquidationBonusBps: 500,
                baseBorrowRate: 0.05e18,
                borrowRateSlope: 0.2e18,
                initialUpgradeAuthority: address(this)
            })
        );

        asset.mint(borrowerOne, 10_000 ether);
        asset.mint(borrowerTwo, 10_000 ether);
        asset.mint(providerOne, 100_000 ether);
        asset.mint(providerTwo, 100_000 ether);

        _approvePool(borrowerOne);
        _approvePool(borrowerTwo);
        _approvePool(providerOne);
        _approvePool(providerTwo);
    }

    function test_DepositCheckpointsOldRateAndPreservesBoundaryAccounting() public {
        _openBorrow(borrowerOne, 1_000 ether, 500 ether, providerOne);
        vm.warp(block.timestamp + 180 days);

        uint256 indexBefore = pool.currentBorrowIndex();
        uint256 debtBefore = pool.debtBalanceOf(borrowerOne);
        uint256 timestamp = block.timestamp;
        uint256 providerBalanceBefore = asset.balanceOf(providerTwo);
        uint256 proxyBalanceBefore = asset.balanceOf(address(pool));

        vm.expectEmit(true, false, false, true, address(pool));
        emit LiquidityDeposited(providerTwo, 9_000 ether);
        vm.prank(providerTwo);
        pool.depositLiquidity(9_000 ether);

        assertEq(pool.borrowIndex(), indexBefore);
        assertEq(pool.currentBorrowIndex(), indexBefore);
        assertEq(pool.debtBalanceOf(borrowerOne), debtBefore);
        assertEq(pool.lastBorrowIndexUpdate(), timestamp);
        assertEq(pool.liquidityBalanceOf(providerTwo), 9_000 ether);
        assertEq(pool.totalLiquidity(), 10_000 ether);
        assertEq(asset.balanceOf(providerTwo), providerBalanceBefore - 9_000 ether);
        assertEq(asset.balanceOf(address(pool)), proxyBalanceBefore + 9_000 ether);
    }

    function test_WithdrawalCheckpointsOldRateAndPreservesBoundaryAccounting() public {
        _openBorrow(borrowerOne, 10_000 ether, 500 ether, providerOne);
        vm.warp(block.timestamp + 180 days);

        uint256 indexBefore = pool.currentBorrowIndex();
        uint256 debtBefore = pool.debtBalanceOf(borrowerOne);
        uint256 availableBefore = pool.availableLiquidity();
        uint256 timestamp = block.timestamp;
        uint256 providerBalanceBefore = asset.balanceOf(providerOne);
        uint256 proxyBalanceBefore = asset.balanceOf(address(pool));

        vm.expectEmit(true, false, false, true, address(pool));
        emit LiquidityWithdrawn(providerOne, 9_000 ether);
        vm.prank(providerOne);
        pool.withdrawLiquidity(9_000 ether);

        assertEq(pool.borrowIndex(), indexBefore);
        assertEq(pool.currentBorrowIndex(), indexBefore);
        assertEq(pool.debtBalanceOf(borrowerOne), debtBefore);
        assertEq(pool.lastBorrowIndexUpdate(), timestamp);
        assertEq(pool.liquidityBalanceOf(providerOne), 1_000 ether);
        assertEq(pool.totalLiquidity(), 1_000 ether);
        assertEq(pool.availableLiquidity(), availableBefore - 9_000 ether);
        assertEq(asset.balanceOf(providerOne), providerBalanceBefore + 9_000 ether);
        assertEq(asset.balanceOf(address(pool)), proxyBalanceBefore - 9_000 ether);
    }

    function test_DepositAppliesLowerRateOnlyToFutureInterval() public {
        _openBorrow(borrowerOne, 1_000 ether, 500 ether, providerOne);
        vm.warp(block.timestamp + 90 days);

        uint256 boundaryIndex = pool.currentBorrowIndex();
        vm.prank(providerTwo);
        pool.depositLiquidity(9_000 ether);

        uint256 futureRate = pool.currentBorrowRate();
        assertEq(pool.borrowIndex(), boundaryIndex);

        vm.warp(block.timestamp + 30 days);

        assertEq(pool.currentBorrowIndex(), _accruedIndex(boundaryIndex, futureRate, 30 days));
    }

    function test_WithdrawalAppliesHigherRateOnlyToFutureInterval() public {
        _openBorrow(borrowerOne, 10_000 ether, 500 ether, providerOne);
        vm.warp(block.timestamp + 90 days);

        uint256 boundaryIndex = pool.currentBorrowIndex();
        vm.prank(providerOne);
        pool.withdrawLiquidity(9_000 ether);

        uint256 futureRate = pool.currentBorrowRate();
        assertEq(pool.borrowIndex(), boundaryIndex);

        vm.warp(block.timestamp + 30 days);

        assertEq(pool.currentBorrowIndex(), _accruedIndex(boundaryIndex, futureRate, 30 days));
    }

    function test_MultipleBorrowersRemainContinuousAndNewBorrowStartsAtPrincipal() public {
        _depositLiquidity(providerOne, 2_000 ether);
        _depositCollateral(borrowerOne, 1_000 ether);
        _depositCollateral(borrowerTwo, 1_000 ether);

        vm.prank(borrowerOne);
        pool.borrow(500 ether);
        vm.warp(block.timestamp + 180 days);
        priceFeed.setUpdatedAt(block.timestamp);

        vm.prank(borrowerTwo);
        pool.borrow(300 ether);

        assertApproxEqAbs(pool.debtBalanceOf(borrowerTwo), 300 ether, 1);

        vm.warp(block.timestamp + 90 days);
        uint256 borrowerOneDebtBefore = pool.debtBalanceOf(borrowerOne);
        uint256 borrowerTwoDebtBefore = pool.debtBalanceOf(borrowerTwo);

        vm.prank(providerTwo);
        pool.depositLiquidity(8_000 ether);

        assertEq(pool.debtBalanceOf(borrowerOne), borrowerOneDebtBefore);
        assertEq(pool.debtBalanceOf(borrowerTwo), borrowerTwoDebtBefore);
    }

    function test_RepeatedLiquidityMutationsKeepIndexMonotonic() public {
        _openBorrow(borrowerOne, 10_000 ether, 500 ether, providerOne);
        uint256 previousIndex = pool.currentBorrowIndex();

        vm.warp(block.timestamp + 30 days);
        vm.prank(providerOne);
        pool.withdrawLiquidity(4_000 ether);
        assertGe(pool.currentBorrowIndex(), previousIndex);
        previousIndex = pool.currentBorrowIndex();

        vm.warp(block.timestamp + 30 days);
        vm.prank(providerTwo);
        pool.depositLiquidity(8_000 ether);
        assertGe(pool.currentBorrowIndex(), previousIndex);
        previousIndex = pool.currentBorrowIndex();

        vm.warp(block.timestamp + 30 days);
        vm.prank(providerOne);
        pool.withdrawLiquidity(3_000 ether);
        assertGe(pool.currentBorrowIndex(), previousIndex);
    }

    function test_RevertedLiquidityMutationsDoNotPersistCheckpoint() public {
        _openBorrow(borrowerOne, 1_000 ether, 500 ether, providerOne);
        vm.warp(block.timestamp + 30 days);

        uint256 storedIndex = pool.borrowIndex();
        uint256 storedTimestamp = pool.lastBorrowIndexUpdate();
        uint256 storedLiquidity = pool.totalLiquidity();
        uint256 storedProviderBalance = pool.liquidityBalanceOf(providerOne);

        vm.prank(providerTwo);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.depositLiquidity(0);
        assertEq(pool.borrowIndex(), storedIndex);
        assertEq(pool.lastBorrowIndexUpdate(), storedTimestamp);

        vm.prank(providerOne);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.withdrawLiquidity(1_001 ether);
        assertEq(pool.borrowIndex(), storedIndex);
        assertEq(pool.lastBorrowIndexUpdate(), storedTimestamp);

        vm.mockCallRevert(
            address(asset),
            abi.encodeWithSelector(asset.transfer.selector, providerOne, 100 ether),
            abi.encode("forced transfer failure")
        );
        vm.prank(providerOne);
        vm.expectRevert();
        pool.withdrawLiquidity(100 ether);
        vm.clearMockedCalls();

        assertEq(pool.borrowIndex(), storedIndex);
        assertEq(pool.lastBorrowIndexUpdate(), storedTimestamp);
        assertEq(pool.totalLiquidity(), storedLiquidity);
        assertEq(pool.liquidityBalanceOf(providerOne), storedProviderBalance);
    }

    function _openBorrow(address borrower, uint256 liquidity, uint256 amount, address provider) internal {
        _depositLiquidity(provider, liquidity);
        _depositCollateral(borrower, 1_000 ether);
        vm.prank(borrower);
        pool.borrow(amount);
    }

    function _depositLiquidity(address provider, uint256 amount) internal {
        vm.prank(provider);
        pool.depositLiquidity(amount);
    }

    function _depositCollateral(address borrower, uint256 amount) internal {
        vm.prank(borrower);
        pool.depositCollateral(amount);
    }

    function _approvePool(address account) internal {
        vm.prank(account);
        asset.approve(address(pool), type(uint256).max);
    }

    function _accruedIndex(uint256 startingIndex, uint256 rate, uint256 elapsed) internal pure returns (uint256) {
        uint256 interestFactor = rate * elapsed / YEAR;
        uint256 secondOrderTerm = interestFactor * interestFactor / (2 * WAD);
        return startingIndex * (WAD + interestFactor + secondOrderTerm) / WAD;
    }
}
