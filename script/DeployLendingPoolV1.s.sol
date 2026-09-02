// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LendingPool} from "../src/core/lending/LendingPool.sol";
import {CollateralVault} from "../src/core/vault/CollateralVault.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {OracleLib} from "../src/lib/OracleLib.sol";

interface ILendingPoolDeploymentView {
    function priceFeed() external view returns (address);
    function vault() external view returns (address);
    function debtAsset() external view returns (address);
    function collateralAsset() external view returns (address);
    function maxPriceStaleness() external view returns (uint256);
    function ltvBps() external view returns (uint256);
    function liquidationThresholdBps() external view returns (uint256);
    function liquidationBonusBps() external view returns (uint256);
    function baseBorrowRate() external view returns (uint256);
    function borrowRateSlope() external view returns (uint256);
    function borrowIndex() external view returns (uint256);
    function lastBorrowIndexUpdate() external view returns (uint256);
    function totalCollateralShares() external view returns (uint256);
    function totalLiquidity() external view returns (uint256);
    function totalScaledDebt() external view returns (uint256);
    function upgradeAuthority() external view returns (address);
    function pendingUpgradeAuthority() external view returns (address);
}

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
        uint256 expectedChainId;
    }

    error InvalidCollateralAsset(address collateralAsset);
    error InvalidDebtAsset(address debtAsset);
    error InvalidPriceFeed(address priceFeed);
    error InvalidInitialUpgradeAuthority(address initialUpgradeAuthority);
    error InvalidMaxPriceStaleness(uint256 maxPriceStaleness);
    error InvalidRiskParameters(uint256 ltvBps, uint256 liquidationThresholdBps, uint256 liquidationBonusBps);
    error InvalidInterestRateModel(uint256 baseBorrowRate, uint256 borrowRateSlope);
    error UnexpectedChainId(uint256 expectedChainId, uint256 actualChainId);
    error CollateralAssetHasNoCode(address collateralAsset);
    error DebtAssetHasNoCode(address debtAsset);
    error PriceFeedHasNoCode(address priceFeed);
    error DependencyInterfaceProbeFailed(address dependency, bytes4 selector);
    error DeploymentArtifactHasNoCode(bytes32 artifact, address artifactAddress);
    error DeploymentArtifactsNotDistinct(
        bytes32 firstArtifact, address firstAddress, bytes32 secondArtifact, address secondAddress
    );
    error LendingPoolProxyAddressMismatch(address expectedProxy, address actualProxy);
    error UnexpectedProxyImplementation(address expectedImplementation, address actualImplementation);
    error ProxiableUUIDReadFailed(address implementation);
    error UnexpectedProxiableUUID(address implementation, bytes32 actualUuid);
    error PostDeploymentInterfaceReadFailed(address target, bytes4 selector);
    error DeploymentValueMismatch(bytes32 field, bytes32 expectedValue, bytes32 actualValue);
    error VaultStringMismatch(bytes32 field);
    error InvalidLastBorrowIndexUpdate(uint256 actualLastBorrowIndexUpdate, uint256 currentTimestamp);

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    // Used only to verify balanceOf ABI success and correctly sized return data.
    address internal constant ERC20_PROBE_ACCOUNT = 0x000000000000000000000000000000000000dEaD;
    bytes32 public constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run()
        external
        returns (CollateralVault vault, LendingPool implementation, ERC1967Proxy proxy, LendingPool pool)
    {
        DeploymentConfig memory config = _readDeploymentConfig();

        validateConfig(config);

        vm.startBroadcast();
        (vault, implementation, proxy, pool) = _deploy(config);
        vm.stopBroadcast();

        validateDeployment(config, vault, implementation, proxy, pool);
        _logDeployment(config, vault, implementation, proxy);
    }

    function deploy(DeploymentConfig memory config)
        public
        returns (CollateralVault vault, LendingPool implementation, ERC1967Proxy proxy, LendingPool pool)
    {
        validateConfig(config);
        (vault, implementation, proxy, pool) = _deploy(config);
        validateDeployment(config, vault, implementation, proxy, pool);
    }

    function _deploy(DeploymentConfig memory config)
        internal
        returns (CollateralVault vault, LendingPool implementation, ERC1967Proxy proxy, LendingPool pool)
    {
        vault = new CollateralVault(
            config.collateralVaultName, config.collateralVaultSymbol, IERC20(config.collateralAsset)
        );
        implementation = new LendingPool();

        bytes memory initializationData = encodeInitializationData(config, address(vault));
        proxy = new ERC1967Proxy(address(implementation), initializationData);
        pool = LendingPool(address(proxy));
    }

    function validateConfig(DeploymentConfig memory config) public view {
        if (config.expectedChainId != block.chainid) {
            revert UnexpectedChainId(config.expectedChainId, block.chainid);
        }
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

        if (config.collateralAsset.code.length == 0) {
            revert CollateralAssetHasNoCode(config.collateralAsset);
        }
        if (config.debtAsset.code.length == 0) {
            revert DebtAssetHasNoCode(config.debtAsset);
        }
        if (config.priceFeed.code.length == 0) {
            revert PriceFeedHasNoCode(config.priceFeed);
        }

        _probeErc20(config.collateralAsset);
        _probeErc20(config.debtAsset);
        _probePriceFeed(config.priceFeed);
        OracleLib.getFreshPriceWad(IPriceFeed(config.priceFeed), config.maxPriceStaleness);
    }

    function validateDeployment(
        DeploymentConfig memory config,
        CollateralVault vault,
        LendingPool implementation,
        ERC1967Proxy proxy,
        LendingPool pool
    ) public view {
        _requireCode("vault", address(vault));
        _requireCode("implementation", address(implementation));
        _requireCode("proxy", address(proxy));
        _requireDistinct("vault", address(vault), "implementation", address(implementation));
        _requireDistinct("vault", address(vault), "proxy", address(proxy));
        _requireDistinct("implementation", address(implementation), "proxy", address(proxy));

        if (address(pool) != address(proxy)) {
            revert LendingPoolProxyAddressMismatch(address(proxy), address(pool));
        }

        address proxyImplementation = address(uint160(uint256(vm.load(address(proxy), ERC1967_IMPLEMENTATION_SLOT))));
        if (proxyImplementation != address(implementation)) {
            revert UnexpectedProxyImplementation(address(implementation), proxyImplementation);
        }
        _validateProxiableUuid(address(implementation));

        _checkAddress("vaultAsset", config.collateralAsset, _readAddress(address(vault), bytes4(keccak256("asset()"))));
        if (keccak256(bytes(vault.name())) != keccak256(bytes(config.collateralVaultName))) {
            revert VaultStringMismatch("vaultName");
        }
        if (keccak256(bytes(vault.symbol())) != keccak256(bytes(config.collateralVaultSymbol))) {
            revert VaultStringMismatch("vaultSymbol");
        }

        _checkAddress(
            "priceFeed", config.priceFeed, _readAddress(address(pool), ILendingPoolDeploymentView.priceFeed.selector)
        );
        _checkAddress("vault", address(vault), _readAddress(address(pool), ILendingPoolDeploymentView.vault.selector));
        _checkAddress(
            "debtAsset", config.debtAsset, _readAddress(address(pool), ILendingPoolDeploymentView.debtAsset.selector)
        );
        _checkAddress(
            "collateralAsset",
            config.collateralAsset,
            _readAddress(address(pool), ILendingPoolDeploymentView.collateralAsset.selector)
        );
        _checkUint(
            "maxPriceStaleness",
            config.maxPriceStaleness,
            _readUint(address(pool), ILendingPoolDeploymentView.maxPriceStaleness.selector)
        );
        _checkUint("ltvBps", config.ltvBps, _readUint(address(pool), ILendingPoolDeploymentView.ltvBps.selector));
        _checkUint(
            "liquidationThresholdBps",
            config.liquidationThresholdBps,
            _readUint(address(pool), ILendingPoolDeploymentView.liquidationThresholdBps.selector)
        );
        _checkUint(
            "liquidationBonusBps",
            config.liquidationBonusBps,
            _readUint(address(pool), ILendingPoolDeploymentView.liquidationBonusBps.selector)
        );
        _checkUint(
            "baseBorrowRate",
            config.baseBorrowRate,
            _readUint(address(pool), ILendingPoolDeploymentView.baseBorrowRate.selector)
        );
        _checkUint(
            "borrowRateSlope",
            config.borrowRateSlope,
            _readUint(address(pool), ILendingPoolDeploymentView.borrowRateSlope.selector)
        );
        _checkUint("borrowIndex", WAD, _readUint(address(pool), ILendingPoolDeploymentView.borrowIndex.selector));
        uint256 lastBorrowIndexUpdate =
            _readUint(address(pool), ILendingPoolDeploymentView.lastBorrowIndexUpdate.selector);
        if (lastBorrowIndexUpdate == 0 || lastBorrowIndexUpdate > block.timestamp) {
            revert InvalidLastBorrowIndexUpdate(lastBorrowIndexUpdate, block.timestamp);
        }
        _checkAddress(
            "upgradeAuthority",
            config.initialUpgradeAuthority,
            _readAddress(address(pool), ILendingPoolDeploymentView.upgradeAuthority.selector)
        );
        _checkAddress(
            "pendingUpgradeAuthority",
            address(0),
            _readAddress(address(pool), ILendingPoolDeploymentView.pendingUpgradeAuthority.selector)
        );

        _checkUint(
            "totalCollateralShares",
            0,
            _readUint(address(pool), ILendingPoolDeploymentView.totalCollateralShares.selector)
        );
        _checkUint("totalLiquidity", 0, _readUint(address(pool), ILendingPoolDeploymentView.totalLiquidity.selector));
        _checkUint("totalScaledDebt", 0, _readUint(address(pool), ILendingPoolDeploymentView.totalScaledDebt.selector));
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
            initialUpgradeAuthority: vm.envAddress("INITIAL_UPGRADE_AUTHORITY"),
            expectedChainId: vm.envUint("EXPECTED_CHAIN_ID")
        });
    }

    function _probeErc20(address asset) internal view {
        bytes4 selector = IERC20.balanceOf.selector;
        (bool success, bytes memory returnData) =
            asset.staticcall(abi.encodeCall(IERC20.balanceOf, (ERC20_PROBE_ACCOUNT)));
        if (!success || returnData.length != 32) {
            revert DependencyInterfaceProbeFailed(asset, selector);
        }
        abi.decode(returnData, (uint256));
    }

    function _probePriceFeed(address priceFeed) internal view {
        bytes4 decimalsSelector = IPriceFeed.decimals.selector;
        (bool decimalsSuccess, bytes memory decimalsData) =
            priceFeed.staticcall(abi.encodeCall(IPriceFeed.decimals, ()));
        if (!decimalsSuccess || decimalsData.length != 32) {
            revert DependencyInterfaceProbeFailed(priceFeed, decimalsSelector);
        }
        uint256 decimalsWord;
        assembly ("memory-safe") {
            decimalsWord := mload(add(decimalsData, 0x20))
        }
        if (decimalsWord > type(uint8).max) {
            revert DependencyInterfaceProbeFailed(priceFeed, decimalsSelector);
        }

        bytes4 roundDataSelector = IPriceFeed.latestRoundData.selector;
        (bool roundDataSuccess, bytes memory roundData) =
            priceFeed.staticcall(abi.encodeCall(IPriceFeed.latestRoundData, ()));
        if (!roundDataSuccess || roundData.length != 160) {
            revert DependencyInterfaceProbeFailed(priceFeed, roundDataSelector);
        }

        uint256 roundIdWord;
        uint256 answeredInRoundWord;
        assembly ("memory-safe") {
            roundIdWord := mload(add(roundData, 0x20))
            answeredInRoundWord := mload(add(roundData, 0xa0))
        }
        if (roundIdWord > type(uint80).max || answeredInRoundWord > type(uint80).max) {
            revert DependencyInterfaceProbeFailed(priceFeed, roundDataSelector);
        }
    }

    function _validateProxiableUuid(address implementation) internal view {
        (bool success, bytes memory returnData) =
            implementation.staticcall(abi.encodeCall(IERC1822Proxiable.proxiableUUID, ()));
        if (!success || returnData.length != 32) {
            revert ProxiableUUIDReadFailed(implementation);
        }

        bytes32 uuid = abi.decode(returnData, (bytes32));
        if (uuid != ERC1967_IMPLEMENTATION_SLOT) {
            revert UnexpectedProxiableUUID(implementation, uuid);
        }
    }

    function _requireCode(bytes32 artifact, address artifactAddress) internal view {
        if (artifactAddress.code.length == 0) {
            revert DeploymentArtifactHasNoCode(artifact, artifactAddress);
        }
    }

    function _requireDistinct(
        bytes32 firstArtifact,
        address firstAddress,
        bytes32 secondArtifact,
        address secondAddress
    ) internal pure {
        if (firstAddress == secondAddress) {
            revert DeploymentArtifactsNotDistinct(firstArtifact, firstAddress, secondArtifact, secondAddress);
        }
    }

    function _readAddress(address target, bytes4 selector) internal view returns (address) {
        uint256 value = uint256(_readWord(target, selector));
        if (value > type(uint160).max) {
            revert PostDeploymentInterfaceReadFailed(target, selector);
        }
        // The preceding upper-bound check proves this conversion cannot truncate non-zero upper bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(value));
    }

    function _readUint(address target, bytes4 selector) internal view returns (uint256) {
        return uint256(_readWord(target, selector));
    }

    function _readWord(address target, bytes4 selector) internal view returns (bytes32 word) {
        (bool success, bytes memory returnData) = target.staticcall(abi.encodeWithSelector(selector));
        if (!success || returnData.length != 32) {
            revert PostDeploymentInterfaceReadFailed(target, selector);
        }
        word = abi.decode(returnData, (bytes32));
    }

    function _checkAddress(bytes32 field, address expected, address actual) internal pure {
        _checkBytes32(field, bytes32(uint256(uint160(expected))), bytes32(uint256(uint160(actual))));
    }

    function _checkUint(bytes32 field, uint256 expected, uint256 actual) internal pure {
        _checkBytes32(field, bytes32(expected), bytes32(actual));
    }

    function _checkBytes32(bytes32 field, bytes32 expected, bytes32 actual) internal pure {
        if (expected != actual) {
            revert DeploymentValueMismatch(field, expected, actual);
        }
    }

    function _logDeployment(
        DeploymentConfig memory config,
        CollateralVault vault,
        LendingPool implementation,
        ERC1967Proxy proxy
    ) internal pure {
        console2.log("Chain ID:", config.expectedChainId);
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
