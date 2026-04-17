// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {CollateralVault} from "../../../src/core/vault/CollateralVault.sol";

contract VaultTest is Test {
    CollateralVault internal vault;
    MockERC20 internal asset;

    address internal user;

    function setUp() public {
        user = makeAddr("user");

        asset = new MockERC20("Asset Token", "ASS");
        vault = new CollateralVault("Vault Share", "VSS", asset);

        asset.mint(user, 1000 ether);

        vm.prank(user);
        asset.approve(address(vault), type(uint256).max);
    }

    function test_Deposit_MintsSharesOneToOne_OnEmptyVault() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        uint256 share = vault.deposit(amount, user);

        assertEq(share, amount);
        assertEq(vault.totalAssets(), amount);
        assertEq(vault.totalSupply(), amount);
    }

    function test_Deposit_UpdatesUserShareBalance() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        uint256 share = vault.deposit(amount, user);

        assertEq(vault.balanceOf(user), amount);
        assertEq(vault.balanceOf(user), share);
    }

    function test_Deposit_CalculatesSharesCorrectly_WhenVaultNotEmpty() public {
        address user2 = makeAddr("bob");
        uint256 amount = 100 ether;

        asset.mint(user2, 1000 ether);

        vm.prank(user2);
        asset.approve(address(vault), type(uint256).max);

        vm.prank(user);
        vault.deposit(amount, user);

        asset.mint(address(vault), amount);

        assertEq(vault.totalAssets(), 200 ether);
        assertEq(vault.totalSupply(), 100 ether);

        uint256 expectedShares = vault.previewDeposit(amount);

        vm.prank(user2);
        uint256 share2 = vault.deposit(amount, user2);

        assertEq(expectedShares, share2);
        assertEq(vault.balanceOf(user2), expectedShares);
    }

    function test_Withdraw_BurnsCorrectShares_ForRequestedAssets() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        vault.deposit(amount, user);

        asset.mint(address(vault), amount);

        assertEq(vault.totalAssets(), 200 ether);
        assertEq(vault.totalSupply(), 100 ether);

        uint256 sharesBefore = vault.balanceOf(user);
        uint256 supplyBefore = vault.totalSupply();

        uint256 sharesExpected = vault.previewWithdraw(amount);

        vm.prank(user);
        vault.withdraw(amount, user, user);

        uint256 sharesAfter = vault.balanceOf(user);

        assertEq(sharesBefore - sharesAfter, sharesExpected);
        assertEq(vault.totalAssets(), 100 ether);
        assertEq(vault.totalSupply(), supplyBefore - sharesExpected);
    }

    function test_Redeem_ReturnsCorrectAssets_WhenVaultNotEmpty() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        vault.deposit(amount, user);

        asset.mint(address(vault), amount);

        assertEq(vault.totalAssets(), 200 ether);
        assertEq(vault.totalSupply(), 100 ether);

        uint256 shares = vault.balanceOf(user) / 2;

        uint256 assetsBefore = asset.balanceOf(user);
        uint256 sharesBefore = vault.balanceOf(user);
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 totalSupplyBefore = vault.totalSupply();

        uint256 expectedAssets = vault.previewRedeem(shares);

        vm.prank(user);
        uint256 assetsReceived = vault.redeem(shares, user, user);

        uint256 assetsAfter = asset.balanceOf(user);
        uint256 sharesAfter = vault.balanceOf(user);

        assertEq(assetsReceived, expectedAssets);
        assertEq(assetsAfter - assetsBefore, assetsReceived);
        assertEq(sharesBefore - sharesAfter, shares);
        assertEq(vault.totalSupply(), totalSupplyBefore - shares);
        assertEq(vault.totalAssets(), totalAssetsBefore - assetsReceived);
    }

    function test_Withdraw_Reverts_WhenAssetsExceedMaxWithdraw() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        vault.deposit(amount, user);

        uint256 maxAssets = vault.maxWithdraw(user);

        vm.prank(user);
        vm.expectRevert();
        vault.withdraw(maxAssets + 1, user, user);
    }

    function test_Donation_IncreasesTotalAssets_ButNotTotalSupply() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        vault.deposit(amount, user);

        uint256 assetsBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();

        asset.mint(address(vault), amount);

        uint256 assetsAfter = vault.totalAssets();
        uint256 supplyAfter = vault.totalSupply();

        assertEq(assetsAfter, assetsBefore + amount);
        assertEq(supplyAfter, supplyBefore);
    }
}
