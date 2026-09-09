// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {LendingPoolProxyFixture} from "../helpers/LendingPoolProxyFixture.sol";

import {CollateralVault} from "../../src/core/vault/CollateralVault.sol";
import {LendingPool} from "../../src/core/lending/LendingPool.sol";
import {LendingPoolV1_2} from "../../src/core/lending/LendingPoolV1_2.sol";
import {LendingPoolHandler} from "./LendingPoolHandler.t.sol";

contract LendingPoolInvariantTest is Test, LendingPoolProxyFixture {
    MockERC20 internal asset;
    CollateralVault internal vault;
    LendingPool internal pool;
    LendingPool internal poolImplementation;
    MockV3Aggregator internal priceFeed;
    LendingPoolHandler internal handler;

    uint256 internal constant WAD = 1e18;

    uint256 internal constant LTV_BPS = 7_000;
    uint256 internal constant LIQUIDATION_THRESHOLD_BPS = 8_000;
    uint256 internal constant LIQUIDATION_BONUS_BPS = 500;
    uint256 internal constant MAX_PRICE_STALENESS = 1 days;

    uint256 internal constant BASE_BORROW_RATE = 0.05e18;
    uint256 internal constant BORROW_RATE_SLOPE = 0.2e18;

    uint8 internal constant PRICE_DECIMALS = 8;
    int256 internal constant INITIAL_PRICE = 1e8;

    address internal user1;
    address internal user2;
    address internal user3;

    function setUp() public {
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        asset = new MockERC20("Asset Token", "ASS");
        vault = new CollateralVault("Vault Share", "VSS", asset);
        priceFeed = new MockV3Aggregator(PRICE_DECIMALS, INITIAL_PRICE, block.timestamp);

        LendingPoolProxyConfig memory config = LendingPoolProxyConfig({
            priceFeed: address(priceFeed),
            vault: address(vault),
            debtAsset: address(asset),
            maxPriceStaleness: MAX_PRICE_STALENESS,
            ltvBps: LTV_BPS,
            liquidationThresholdBps: LIQUIDATION_THRESHOLD_BPS,
            liquidationBonusBps: LIQUIDATION_BONUS_BPS,
            baseBorrowRate: BASE_BORROW_RATE,
            borrowRateSlope: BORROW_RATE_SLOPE,
            initialUpgradeAuthority: address(this)
        });

        poolImplementation = _newImplementation();
        pool = _deployLendingPoolProxy(poolImplementation, config);

        (bool hasVersion, bytes memory versionData) =
            address(poolImplementation).staticcall(abi.encodeCall(LendingPoolV1_2.version, ()));
        if (hasVersion && keccak256(bytes(abi.decode(versionData, (string)))) == keccak256(bytes("1.2"))) {
            LendingPoolV1_2(address(pool)).migrateToV1_2();
        }

        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;

        handler = new LendingPoolHandler(pool, asset, priceFeed, users);

        asset.mint(address(this), type(uint128).max);
        asset.approve(address(pool), type(uint128).max);

        targetContract(address(handler));
    }

    function invariant_AvailableLiquidityNeverExceedsTotalLiquidity() public view {
        assertLe(pool.availableLiquidity(), pool.totalLiquidity());
    }

    function invariant_TotalScaledDebtEqualsSumOfUserScaledDebt() public view {
        uint256 sum;

        for (uint256 i = 0; i < handler.userCount(); i++) {
            address user = handler.users(i);
            sum += pool.scaledDebtOf(user);
        }

        assertEq(pool.totalScaledDebt(), sum);
    }

    function invariant_TotalDebtApproximatelyEqualsSumOfUserDebt() public view {
        uint256 sum;
        uint256 nonzeroAccounts;

        for (uint256 i = 0; i < handler.userCount(); i++) {
            address user = handler.users(i);
            sum += pool.debtBalanceOf(user);
            if (pool.scaledDebtOf(user) != 0) ++nonzeroAccounts;
        }

        assertGe(pool.totalDebt(), sum);
        if (nonzeroAccounts == 0) {
            assertEq(pool.totalDebt(), 0);
        } else {
            assertLe(pool.totalDebt() - sum, nonzeroAccounts - 1);
        }
    }

    function invariant_TotalCollateralSharesEqualsSumOfUserShares() public view {
        uint256 sum;

        for (uint256 i = 0; i < handler.userCount(); i++) {
            address user = handler.users(i);
            sum += pool.collateralSharesOf(user);
        }

        assertEq(pool.totalCollateralShares(), sum);
    }

    function invariant_TotalLiquidityEqualsSumOfTrackedProviderBalances() public view {
        uint256 sum = pool.liquidityBalanceOf(address(handler));

        for (uint256 i = 0; i < handler.userCount(); i++) {
            sum += pool.liquidityBalanceOf(handler.users(i));
        }

        assertEq(pool.totalLiquidity(), sum);
    }

    function invariant_BorrowIndexNeverDecreases() public view {
        assertGe(pool.currentBorrowIndex(), pool.borrowIndex());
        assertGe(pool.borrowIndex(), WAD);
    }

    function invariant_NoUserHasImpossibleZeroScaledDebtState() public view {
        for (uint256 i = 0; i < handler.userCount(); i++) {
            address user = handler.users(i);

            if (pool.scaledDebtOf(user) == 0) {
                assertEq(pool.debtBalanceOf(user), 0);
            }
        }
    }

    function invariant_ProtocolAssetBalanceCoversAvailableLiquidityWithRoundingTolerance() public view {
        uint256 balance = asset.balanceOf(address(pool));
        uint256 available = pool.availableLiquidity();

        assertGe(balance + handler.successfulBorrowCalls(), available);
    }

    function invariant_HealthyUsersCannotBeLiquidated() public {
        for (uint256 i = 0; i < handler.userCount(); i++) {
            address user = handler.users(i);

            uint256 debt = pool.debtBalanceOf(user);
            if (debt == 0) continue;

            uint256 healthFactor = pool.getHealthFactor(user);
            if (healthFactor < WAD) continue;

            vm.expectRevert(LendingPool.PositionNotLiquidatable.selector);
            pool.liquidate(user, debt);
        }
    }

    function afterInvariant() public view {
        assertGt(handler.attemptedBorrowCalls(), 0);
        assertGt(handler.successfulBorrowCalls(), 0);
        assertGt(handler.attemptedLiquidationCalls(), 0);
        assertGt(handler.successfulLiquidationCalls(), 0);
        assertGe(handler.attemptedExternalLiquidityDepositCalls(), 2);
        assertEq(handler.successfulExternalLiquidityDepositCalls(), handler.attemptedExternalLiquidityDepositCalls());
        assertGe(handler.distinctLiquidityProviders(), 2);
        assertGt(handler.attemptedLiquidityWithdrawalCalls(), 0);
        assertEq(handler.successfulLiquidityWithdrawalCalls(), handler.attemptedLiquidityWithdrawalCalls());
        assertGt(handler.attemptedCollateralWithdrawalCalls(), 0);
        assertEq(handler.successfulCollateralWithdrawalCalls(), handler.attemptedCollateralWithdrawalCalls());

        assertEq(
            handler.successfulBorrowCalls() + handler.expectedRejectedBorrowCalls(), handler.attemptedBorrowCalls()
        );
        assertEq(
            handler.successfulLiquidationCalls() + handler.expectedRejectedLiquidationCalls(),
            handler.attemptedLiquidationCalls()
        );
    }

    function _newImplementation() internal virtual returns (LendingPool) {
        return new LendingPool();
    }
}

contract LendingPoolV1_2InvariantTest is LendingPoolInvariantTest {
    function _newImplementation() internal override returns (LendingPool) {
        return new LendingPoolV1_2();
    }
}
