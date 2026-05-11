// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

import {CollateralVault} from "../../src/core/vault/CollateralVault.sol";
import {LendingPool} from "../../src/core/lending/LendingPool.sol";
import {LendingPoolHandler} from "./LendingPoolHandler.t.sol";

contract LendingPoolInvariantTest is Test {
    MockERC20 internal asset;
    CollateralVault internal vault;
    LendingPool internal pool;
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

        pool = new LendingPool(
            address(priceFeed),
            address(vault),
            address(asset),
            MAX_PRICE_STALENESS,
            LTV_BPS,
            LIQUIDATION_THRESHOLD_BPS,
            LIQUIDATION_BONUS_BPS,
            BASE_BORROW_RATE,
            BORROW_RATE_SLOPE
        );

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

        for (uint256 i = 0; i < handler.userCount(); i++) {
            address user = handler.users(i);
            sum += pool.debtBalanceOf(user);
        }

        assertApproxEqAbs(pool.totalDebt(), sum, handler.userCount());
    }

    function invariant_TotalCollateralSharesEqualsSumOfUserShares() public view {
        uint256 sum;

        for (uint256 i = 0; i < handler.userCount(); i++) {
            address user = handler.users(i);
            sum += pool.collateralSharesOf(user);
        }

        assertEq(pool.totalCollateralShares(), sum);
    }

    function invariant_TotalLiquidityEqualsSingleHandlerLiquidityBalance() public view {
        // NOTE: The invariant handler uses a single LP: address(handler).
        // If multi-LP handler actions are added later, this invariant must be generalized.
        assertEq(pool.totalLiquidity(), pool.liquidityBalanceOf(address(handler)));
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

        assertGe(balance + handler.successfulBorrows(), available);
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
}
