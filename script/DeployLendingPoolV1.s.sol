// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LendingPool} from "../src/core/lending/LendingPool.sol";
import {CollateralVault} from "../src/core/vault/CollateralVault.sol";

contract DeployLendingPoolV1 is Script {
    struct DeploymentConfig {
        address collateralAsset;
        address debtAsset;
        address priceFeed;
        string collateralVaultName;
        string collateralVaultSymbol;
        uint256 maxPriceStaleness;
        uint256 ltvBps;
        uint256 liquidationThresholdBps;
        uint256 liquidationBonusBps;
        uint256 baseBorrowRate;
        uint256 borrowRateSlope;
        address initialUpgradeAuthority;
    }

    error InvalidCollateralAsset(address collateralAsset);
    error InvalidDebtAsset(address debtAsset);
    error InvalidPriceFeed(address priceFeed);
    error InvalidInitialUpgradeAuthority(address initialUpgradeAuthority);
    error InvalidMaxPriceStaleness(uint256 maxPriceStaleness);
    error InvalidRiskParameters(uint256 ltvBps, uint256 liquidationThresholdBps, uint256 liquidationBonusBps);
    error InvalidInterestRateModel(uint256 baseBorrowRate, uint256 borrowRateSlope);

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    function run()
        external
        returns (CollateralVault vault, LendingPool implementation, ERC1967Proxy proxy, LendingPool pool)
    {
        DeploymentConfig memory config = _readDeploymentConfig();

        validateConfig(config);

        vm.startBroadcast();
        (vault, implementation, proxy, pool) = deploy(config);
        vm.stopBroadcast();

        _logDeployment(config, vault, implementation, proxy);
    }

    function deploy(DeploymentConfig memory config)
        public
        returns (CollateralVault vault, LendingPool implementation, ERC1967Proxy proxy, LendingPool pool)
    {
        validateConfig(config);

        vault = new CollateralVault(
            config.collateralVaultName, config.collateralVaultSymbol, IERC20(config.collateralAsset)
        );
        implementation = new LendingPool();

        bytes memory initializationData = encodeInitializationData(config, address(vault));
        proxy = new ERC1967Proxy(address(implementation), initializationData);
        pool = LendingPool(address(proxy));
    }

    function validateConfig(DeploymentConfig memory config) public pure {
        if (config.collateralAsset == address(0)) {
            revert InvalidCollateralAsset(config.collateralAsset);
        }
        if (config.debtAsset == address(0)) {
            revert InvalidDebtAsset(config.debtAsset);
        }
        if (config.priceFeed == address(0)) {
            revert InvalidPriceFeed(config.priceFeed);
        }
        if (config.initialUpgradeAuthority == address(0)) {
            revert InvalidInitialUpgradeAuthority(config.initialUpgradeAuthority);
        }
        if (config.maxPriceStaleness == 0) {
            revert InvalidMaxPriceStaleness(config.maxPriceStaleness);
        }
        if (
            config.ltvBps == 0 || config.liquidationThresholdBps == 0 || config.liquidationBonusBps == 0
                || config.ltvBps >= config.liquidationThresholdBps || config.liquidationThresholdBps > BPS
                || config.liquidationBonusBps > BPS
        ) {
            revert InvalidRiskParameters(config.ltvBps, config.liquidationThresholdBps, config.liquidationBonusBps);
        }
        if (config.baseBorrowRate > WAD || config.borrowRateSlope > WAD - config.baseBorrowRate) {
            revert InvalidInterestRateModel(config.baseBorrowRate, config.borrowRateSlope);
        }
    }

    function encodeInitializationData(DeploymentConfig memory config, address vault)
        public
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(
            LendingPool.initialize,
            (
                config.priceFeed,
                vault,
                config.debtAsset,
                config.maxPriceStaleness,
                config.ltvBps,
                config.liquidationThresholdBps,
                config.liquidationBonusBps,
                config.baseBorrowRate,
                config.borrowRateSlope,
                config.initialUpgradeAuthority
            )
        );
    }

    function _readDeploymentConfig() internal view returns (DeploymentConfig memory config) {
        config = DeploymentConfig({
            collateralAsset: vm.envAddress("COLLATERAL_ASSET"),
            debtAsset: vm.envAddress("DEBT_ASSET"),
            priceFeed: vm.envAddress("PRICE_FEED"),
            collateralVaultName: vm.envString("COLLATERAL_VAULT_NAME"),
            collateralVaultSymbol: vm.envString("COLLATERAL_VAULT_SYMBOL"),
            maxPriceStaleness: vm.envUint("MAX_PRICE_STALENESS"),
            ltvBps: vm.envUint("LTV_BPS"),
            liquidationThresholdBps: vm.envUint("LIQUIDATION_THRESHOLD_BPS"),
            liquidationBonusBps: vm.envUint("LIQUIDATION_BONUS_BPS"),
            baseBorrowRate: vm.envUint("BASE_BORROW_RATE"),
            borrowRateSlope: vm.envUint("BORROW_RATE_SLOPE"),
            initialUpgradeAuthority: vm.envAddress("INITIAL_UPGRADE_AUTHORITY")
        });
    }

    function _logDeployment(
        DeploymentConfig memory config,
        CollateralVault vault,
        LendingPool implementation,
        ERC1967Proxy proxy
    ) internal pure {
        console2.log("Collateral asset:", config.collateralAsset);
        console2.log("Debt asset:", config.debtAsset);
        console2.log("Price feed:", config.priceFeed);
        console2.log("Collateral vault:", address(vault));
        console2.log("LendingPool V1 implementation:", address(implementation));
        console2.log("LendingPool proxy:", address(proxy));
        console2.log("Initial upgrade authority:", config.initialUpgradeAuthority);
        console2.log("Max price staleness:", config.maxPriceStaleness);
        console2.log("LTV BPS:", config.ltvBps);
        console2.log("Liquidation threshold BPS:", config.liquidationThresholdBps);
        console2.log("Liquidation bonus BPS:", config.liquidationBonusBps);
        console2.log("Base borrow rate:", config.baseBorrowRate);
        console2.log("Borrow rate slope:", config.borrowRateSlope);
    }
}
