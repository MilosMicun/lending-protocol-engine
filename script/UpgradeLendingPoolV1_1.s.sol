// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LendingPool} from "../src/core/lending/LendingPool.sol";
import {LendingPoolV1_1} from "../src/core/lending/LendingPoolV1_1.sol";

interface ILendingPoolSnapshotView {
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
}

library LendingPoolV1_1UpgradeStateFingerprint {
    bytes32 internal constant DOMAIN_SEPARATOR = keccak256("LendingPoolV1.1UpgradeStateFingerprint/v1");

    struct ConfigurationSnapshot {
        address priceFeed;
        address vault;
        address debtAsset;
        address collateralAsset;
        uint256 maxPriceStaleness;
        uint256 ltvBps;
        uint256 liquidationThresholdBps;
        uint256 liquidationBonusBps;
        uint256 baseBorrowRate;
        uint256 borrowRateSlope;
    }

    struct AccountingSnapshot {
        uint256 borrowIndex;
        uint256 lastBorrowIndexUpdate;
        uint256 totalCollateralShares;
        uint256 totalLiquidity;
        uint256 totalScaledDebt;
    }

    struct CustodySnapshot {
        uint256 proxyDebtAssetBalance;
        uint256 proxyVaultShareBalance;
        uint256 vaultTotalAssets;
        uint256 vaultTotalSupply;
        uint256 vaultCollateralAssetBalance;
    }

    struct ImplementationCustodySnapshot {
        address implementation;
        uint256 collateralAssetBalance;
        uint256 debtAssetBalance;
        uint256 vaultShareBalance;
    }

    struct State {
        uint256 chainId;
        address proxy;
        address expectedOldImplementation;
        address expectedNewImplementation;
        bytes32[18] legacySlots;
        address activeUpgradeAuthority;
        address pendingUpgradeAuthority;
        ConfigurationSnapshot configuration;
        AccountingSnapshot accounting;
        CustodySnapshot custody;
        ImplementationCustodySnapshot oldImplementationCustody;
        ImplementationCustodySnapshot newImplementationCustody;
    }

    function calculate(State memory state) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_SEPARATOR, state));
    }
}

contract UpgradeLendingPoolV1_1 is Script {
    struct UpgradeConfig {
        address lendingPoolProxy;
        address expectedCurrentImplementation;
        address expectedUpgradeAuthority;
        address expectedPendingUpgradeAuthority;
        uint256 expectedChainId;
    }

    struct UpgradeSnapshot {
        address lendingPoolProxy;
        bytes32 implementationWord;
        address activeUpgradeAuthority;
        address pendingUpgradeAuthority;
        bytes32[18] legacySlots;
        LendingPoolV1_1UpgradeStateFingerprint.ConfigurationSnapshot configuration;
        LendingPoolV1_1UpgradeStateFingerprint.AccountingSnapshot accounting;
        LendingPoolV1_1UpgradeStateFingerprint.CustodySnapshot custody;
    }

    struct PreparedTransaction {
        address proxy;
        address expectedCurrentImplementation;
        address newImplementation;
        address expectedUpgradeAuthority;
        address target;
        uint256 value;
        bytes data;
        bytes32 preUpgradeStateHash;
    }

    error InvalidLendingPoolProxy(address lendingPoolProxy);
    error LendingPoolProxyHasNoCode(address lendingPoolProxy);
    error InvalidExpectedCurrentImplementation(address expectedCurrentImplementation);
    error ExpectedCurrentImplementationHasNoCode(address expectedCurrentImplementation);
    error InvalidExpectedUpgradeAuthority(address expectedUpgradeAuthority);
    error UnexpectedChainId(uint256 expectedChainId, uint256 actualChainId);
    error UnexpectedCurrentImplementation(bytes32 expectedImplementationWord, bytes32 actualImplementationWord);
    error UnexpectedActiveUpgradeAuthority(address expectedAuthority, address actualAuthority);
    error UnexpectedPendingUpgradeAuthority(address expectedAuthority, address actualAuthority);
    error ProxiableUUIDReadFailed(address implementation);
    error UnexpectedProxiableUUID(address implementation, bytes32 actualUuid);
    error LendingPoolProxyInterfaceReadFailed(address lendingPoolProxy, bytes4 selector);
    error SnapshotReadFailed(address target, bytes4 selector);
    error NewImplementationHasNoCode(address implementation);
    error NewImplementationMatchesProxy(address implementation);
    error NewImplementationMatchesCurrentImplementation(address implementation);
    error ProxyAddressChanged(address expectedProxy, address actualProxy);
    error PreparedImplementationAddressMismatch(address expectedImplementation, address actualImplementation);
    error VersionReadFailed(address implementation);
    error UnexpectedVersion(string actualVersion);
    error SnapshotValueChanged(bytes32 field, bytes32 expectedValue, bytes32 actualValue);
    error UnexpectedImplementationCustodySnapshot(address expectedImplementation, address actualImplementation);
    error ImplementationCustodyBalanceChanged(
        address implementation, address asset, uint256 expectedBalance, uint256 actualBalance
    );

    bytes32 public constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external returns (PreparedTransaction memory prepared) {
        UpgradeConfig memory config = _readUpgradeConfig();

        validatePreUpgrade(config);
        UpgradeSnapshot memory beforePreparation = snapshot(config.lendingPoolProxy);
        LendingPoolV1_1UpgradeStateFingerprint.ImplementationCustodySnapshot memory oldImplementationCustody =
            snapshotImplementationCustody(beforePreparation.configuration, config.expectedCurrentImplementation);

        vm.startBroadcast();
        address expectedNewImplementation = _nextDeploymentAddress(_broadcastSender());
        LendingPoolV1_1UpgradeStateFingerprint.ImplementationCustodySnapshot memory newImplementationCustody =
            snapshotImplementationCustody(beforePreparation.configuration, expectedNewImplementation);
        LendingPoolV1_1 newImplementation = deployV11(config);
        vm.stopBroadcast();

        prepared = _validateAndPrepare(
            config, beforePreparation, address(newImplementation), oldImplementationCustody, newImplementationCustody
        );
        _logPreparation(prepared);
    }

    function prepare(UpgradeConfig memory config) public returns (PreparedTransaction memory prepared) {
        validatePreUpgrade(config);
        UpgradeSnapshot memory beforePreparation = snapshot(config.lendingPoolProxy);
        LendingPoolV1_1UpgradeStateFingerprint.ImplementationCustodySnapshot memory oldImplementationCustody =
            snapshotImplementationCustody(beforePreparation.configuration, config.expectedCurrentImplementation);
        address expectedNewImplementation = _nextDeploymentAddress(address(this));
        LendingPoolV1_1UpgradeStateFingerprint.ImplementationCustodySnapshot memory newImplementationCustody =
            snapshotImplementationCustody(beforePreparation.configuration, expectedNewImplementation);

        LendingPoolV1_1 newImplementation = deployV11(config);

        prepared = _validateAndPrepare(
            config, beforePreparation, address(newImplementation), oldImplementationCustody, newImplementationCustody
        );
    }

    function validateConfig(UpgradeConfig memory config) public view {
        if (config.lendingPoolProxy == address(0)) {
            revert InvalidLendingPoolProxy(config.lendingPoolProxy);
        }
        if (config.expectedCurrentImplementation == address(0)) {
            revert InvalidExpectedCurrentImplementation(config.expectedCurrentImplementation);
        }
        if (config.expectedUpgradeAuthority == address(0)) {
            revert InvalidExpectedUpgradeAuthority(config.expectedUpgradeAuthority);
        }
        if (config.expectedChainId != block.chainid) {
            revert UnexpectedChainId(config.expectedChainId, block.chainid);
        }
    }

    function validatePreUpgrade(UpgradeConfig memory config) public view {
        validateConfig(config);

        if (config.lendingPoolProxy.code.length == 0) {
            revert LendingPoolProxyHasNoCode(config.lendingPoolProxy);
        }
        if (config.expectedCurrentImplementation.code.length == 0) {
            revert ExpectedCurrentImplementationHasNoCode(config.expectedCurrentImplementation);
        }

        bytes32 implementationWord = vm.load(config.lendingPoolProxy, ERC1967_IMPLEMENTATION_SLOT);
        bytes32 expectedImplementationWord = _addressWord(config.expectedCurrentImplementation);
        if (implementationWord != expectedImplementationWord) {
            revert UnexpectedCurrentImplementation(expectedImplementationWord, implementationWord);
        }

        _validateProxiableUuid(config.expectedCurrentImplementation);

        address activeAuthority = _readProxyAddress(config.lendingPoolProxy, LendingPool.upgradeAuthority.selector);
        if (activeAuthority != config.expectedUpgradeAuthority) {
            revert UnexpectedActiveUpgradeAuthority(config.expectedUpgradeAuthority, activeAuthority);
        }

        address pendingAuthority =
            _readProxyAddress(config.lendingPoolProxy, LendingPool.pendingUpgradeAuthority.selector);
        if (pendingAuthority != config.expectedPendingUpgradeAuthority) {
            revert UnexpectedPendingUpgradeAuthority(config.expectedPendingUpgradeAuthority, pendingAuthority);
        }

        snapshot(config.lendingPoolProxy);
    }

    function snapshot(address lendingPoolProxy) public view returns (UpgradeSnapshot memory state) {
        state.lendingPoolProxy = lendingPoolProxy;
        state.implementationWord = vm.load(lendingPoolProxy, ERC1967_IMPLEMENTATION_SLOT);
        state.activeUpgradeAuthority = _readProxyAddress(lendingPoolProxy, LendingPool.upgradeAuthority.selector);
        state.pendingUpgradeAuthority =
            _readProxyAddress(lendingPoolProxy, LendingPool.pendingUpgradeAuthority.selector);

        for (uint256 slot; slot < state.legacySlots.length; ++slot) {
            state.legacySlots[slot] = vm.load(lendingPoolProxy, bytes32(slot));
        }

        state.configuration = _snapshotConfiguration(lendingPoolProxy);
        state.accounting = _snapshotAccounting(lendingPoolProxy);
        state.custody = _snapshotCustody(lendingPoolProxy, state.configuration);
    }

    function snapshotImplementationCustody(
        LendingPoolV1_1UpgradeStateFingerprint.ConfigurationSnapshot memory config,
        address implementation
    ) public view returns (LendingPoolV1_1UpgradeStateFingerprint.ImplementationCustodySnapshot memory custody) {
        custody.implementation = implementation;
        custody.collateralAssetBalance = _readBalance(config.collateralAsset, implementation);
        custody.debtAssetBalance = _readBalance(config.debtAsset, implementation);
        custody.vaultShareBalance = _readBalance(config.vault, implementation);
    }

    function deployV11(UpgradeConfig memory config) public returns (LendingPoolV1_1 newImplementation) {
        newImplementation = new LendingPoolV1_1();
        address implementation = address(newImplementation);

        if (implementation.code.length == 0) {
            revert NewImplementationHasNoCode(implementation);
        }
        if (implementation == config.lendingPoolProxy) {
            revert NewImplementationMatchesProxy(implementation);
        }
        if (implementation == config.expectedCurrentImplementation) {
            revert NewImplementationMatchesCurrentImplementation(implementation);
        }

        _validateProxiableUuid(implementation);
        _validateVersion(implementation);
    }

    function encodeUpgradeCall(address newImplementation) public pure returns (bytes memory) {
        return abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, newImplementation, bytes(""));
    }

    function calculateStateFingerprint(
        uint256 chainId,
        address expectedOldImplementation,
        address expectedNewImplementation,
        UpgradeSnapshot memory state,
        LendingPoolV1_1UpgradeStateFingerprint.ImplementationCustodySnapshot memory oldImplementationCustody,
        LendingPoolV1_1UpgradeStateFingerprint.ImplementationCustodySnapshot memory newImplementationCustody
    ) public pure returns (bytes32) {
        return LendingPoolV1_1UpgradeStateFingerprint.calculate(
            LendingPoolV1_1UpgradeStateFingerprint.State({
                chainId: chainId,
                proxy: state.lendingPoolProxy,
                expectedOldImplementation: expectedOldImplementation,
                expectedNewImplementation: expectedNewImplementation,
                legacySlots: state.legacySlots,
                activeUpgradeAuthority: state.activeUpgradeAuthority,
                pendingUpgradeAuthority: state.pendingUpgradeAuthority,
                configuration: state.configuration,
                accounting: state.accounting,
                custody: state.custody,
                oldImplementationCustody: oldImplementationCustody,
                newImplementationCustody: newImplementationCustody
            })
        );
    }

    function validatePreservedState(UpgradeSnapshot memory beforeUpgrade) public view {
        UpgradeSnapshot memory afterUpgrade = snapshot(beforeUpgrade.lendingPoolProxy);

        if (afterUpgrade.lendingPoolProxy != beforeUpgrade.lendingPoolProxy) {
            revert ProxyAddressChanged(beforeUpgrade.lendingPoolProxy, afterUpgrade.lendingPoolProxy);
        }

        _checkBytes32("implementation", beforeUpgrade.implementationWord, afterUpgrade.implementationWord);

        _checkAddress("activeAuthority", beforeUpgrade.activeUpgradeAuthority, afterUpgrade.activeUpgradeAuthority);
        _checkAddress("pendingAuthority", beforeUpgrade.pendingUpgradeAuthority, afterUpgrade.pendingUpgradeAuthority);

        for (uint256 slot; slot < beforeUpgrade.legacySlots.length; ++slot) {
            _checkBytes32(bytes32(slot), beforeUpgrade.legacySlots[slot], afterUpgrade.legacySlots[slot]);
        }

        _validateConfiguration(beforeUpgrade.configuration, afterUpgrade.configuration);
        _validateAccounting(beforeUpgrade.accounting, afterUpgrade.accounting);
        _validateCustody(beforeUpgrade.custody, afterUpgrade.custody);
    }

    function _validateAndPrepare(
        UpgradeConfig memory config,
        UpgradeSnapshot memory beforePreparation,
        address newImplementation,
        LendingPoolV1_1UpgradeStateFingerprint.ImplementationCustodySnapshot memory oldImplementationCustody,
        LendingPoolV1_1UpgradeStateFingerprint.ImplementationCustodySnapshot memory newImplementationCustody
    ) internal view returns (PreparedTransaction memory prepared) {
        if (beforePreparation.lendingPoolProxy != config.lendingPoolProxy) {
            revert ProxyAddressChanged(config.lendingPoolProxy, beforePreparation.lendingPoolProxy);
        }

        _validateImplementationCustodySnapshotAddress(
            config.expectedCurrentImplementation, oldImplementationCustody.implementation
        );
        if (newImplementationCustody.implementation != newImplementation) {
            revert PreparedImplementationAddressMismatch(newImplementationCustody.implementation, newImplementation);
        }

        bytes32 expectedPreviousWord = _addressWord(config.expectedCurrentImplementation);
        if (beforePreparation.implementationWord != expectedPreviousWord) {
            revert UnexpectedCurrentImplementation(expectedPreviousWord, beforePreparation.implementationWord);
        }

        _validateProxiableUuid(newImplementation);
        _validateVersion(newImplementation);
        validatePreservedState(beforePreparation);
        _validateImplementationCustodyUnchanged(beforePreparation.configuration, oldImplementationCustody);
        _validateImplementationCustodyUnchanged(beforePreparation.configuration, newImplementationCustody);

        bytes32 preUpgradeStateHash = calculateStateFingerprint(
            config.expectedChainId,
            config.expectedCurrentImplementation,
            newImplementation,
            beforePreparation,
            oldImplementationCustody,
            newImplementationCustody
        );

        prepared = PreparedTransaction({
            proxy: config.lendingPoolProxy,
            expectedCurrentImplementation: config.expectedCurrentImplementation,
            newImplementation: newImplementation,
            expectedUpgradeAuthority: config.expectedUpgradeAuthority,
            target: config.lendingPoolProxy,
            value: 0,
            data: encodeUpgradeCall(newImplementation),
            preUpgradeStateHash: preUpgradeStateHash
        });
    }

    function _snapshotConfiguration(address proxy)
        internal
        view
        returns (LendingPoolV1_1UpgradeStateFingerprint.ConfigurationSnapshot memory config)
    {
        config.priceFeed = _readProxyAddress(proxy, ILendingPoolSnapshotView.priceFeed.selector);
        config.vault = _readProxyAddress(proxy, ILendingPoolSnapshotView.vault.selector);
        config.debtAsset = _readProxyAddress(proxy, ILendingPoolSnapshotView.debtAsset.selector);
        config.collateralAsset = _readProxyAddress(proxy, ILendingPoolSnapshotView.collateralAsset.selector);
        config.maxPriceStaleness = _readProxyUint(proxy, ILendingPoolSnapshotView.maxPriceStaleness.selector);
        config.ltvBps = _readProxyUint(proxy, ILendingPoolSnapshotView.ltvBps.selector);
        config.liquidationThresholdBps =
            _readProxyUint(proxy, ILendingPoolSnapshotView.liquidationThresholdBps.selector);
        config.liquidationBonusBps = _readProxyUint(proxy, ILendingPoolSnapshotView.liquidationBonusBps.selector);
        config.baseBorrowRate = _readProxyUint(proxy, ILendingPoolSnapshotView.baseBorrowRate.selector);
        config.borrowRateSlope = _readProxyUint(proxy, ILendingPoolSnapshotView.borrowRateSlope.selector);
    }

    function _snapshotAccounting(address proxy)
        internal
        view
        returns (LendingPoolV1_1UpgradeStateFingerprint.AccountingSnapshot memory accounting)
    {
        accounting.borrowIndex = _readProxyUint(proxy, ILendingPoolSnapshotView.borrowIndex.selector);
        accounting.lastBorrowIndexUpdate =
            _readProxyUint(proxy, ILendingPoolSnapshotView.lastBorrowIndexUpdate.selector);
        accounting.totalCollateralShares =
            _readProxyUint(proxy, ILendingPoolSnapshotView.totalCollateralShares.selector);
        accounting.totalLiquidity = _readProxyUint(proxy, ILendingPoolSnapshotView.totalLiquidity.selector);
        accounting.totalScaledDebt = _readProxyUint(proxy, ILendingPoolSnapshotView.totalScaledDebt.selector);
    }

    function _snapshotCustody(address proxy, LendingPoolV1_1UpgradeStateFingerprint.ConfigurationSnapshot memory config)
        internal
        view
        returns (LendingPoolV1_1UpgradeStateFingerprint.CustodySnapshot memory custody)
    {
        custody.proxyDebtAssetBalance = _readBalance(config.debtAsset, proxy);
        custody.proxyVaultShareBalance = _readBalance(config.vault, proxy);
        custody.vaultTotalAssets = _readExternalUint(config.vault, abi.encodeWithSignature("totalAssets()"));
        custody.vaultTotalSupply = _readExternalUint(config.vault, abi.encodeWithSignature("totalSupply()"));
        custody.vaultCollateralAssetBalance = _readBalance(config.collateralAsset, config.vault);
    }

    function _validateConfiguration(
        LendingPoolV1_1UpgradeStateFingerprint.ConfigurationSnapshot memory expected,
        LendingPoolV1_1UpgradeStateFingerprint.ConfigurationSnapshot memory actual
    ) internal pure {
        _checkAddress("priceFeed", expected.priceFeed, actual.priceFeed);
        _checkAddress("vault", expected.vault, actual.vault);
        _checkAddress("debtAsset", expected.debtAsset, actual.debtAsset);
        _checkAddress("collateralAsset", expected.collateralAsset, actual.collateralAsset);
        _checkUint("maxPriceStaleness", expected.maxPriceStaleness, actual.maxPriceStaleness);
        _checkUint("ltvBps", expected.ltvBps, actual.ltvBps);
        _checkUint("liquidationThresholdBps", expected.liquidationThresholdBps, actual.liquidationThresholdBps);
        _checkUint("liquidationBonusBps", expected.liquidationBonusBps, actual.liquidationBonusBps);
        _checkUint("baseBorrowRate", expected.baseBorrowRate, actual.baseBorrowRate);
        _checkUint("borrowRateSlope", expected.borrowRateSlope, actual.borrowRateSlope);
    }

    function _validateAccounting(
        LendingPoolV1_1UpgradeStateFingerprint.AccountingSnapshot memory expected,
        LendingPoolV1_1UpgradeStateFingerprint.AccountingSnapshot memory actual
    ) internal pure {
        _checkUint("borrowIndex", expected.borrowIndex, actual.borrowIndex);
        _checkUint("lastBorrowIndexUpdate", expected.lastBorrowIndexUpdate, actual.lastBorrowIndexUpdate);
        _checkUint("totalCollateralShares", expected.totalCollateralShares, actual.totalCollateralShares);
        _checkUint("totalLiquidity", expected.totalLiquidity, actual.totalLiquidity);
        _checkUint("totalScaledDebt", expected.totalScaledDebt, actual.totalScaledDebt);
    }

    function _validateCustody(
        LendingPoolV1_1UpgradeStateFingerprint.CustodySnapshot memory expected,
        LendingPoolV1_1UpgradeStateFingerprint.CustodySnapshot memory actual
    ) internal pure {
        _checkUint("proxyDebtBalance", expected.proxyDebtAssetBalance, actual.proxyDebtAssetBalance);
        _checkUint("proxyVaultShares", expected.proxyVaultShareBalance, actual.proxyVaultShareBalance);
        _checkUint("vaultTotalAssets", expected.vaultTotalAssets, actual.vaultTotalAssets);
        _checkUint("vaultTotalSupply", expected.vaultTotalSupply, actual.vaultTotalSupply);
        _checkUint("vaultCollateral", expected.vaultCollateralAssetBalance, actual.vaultCollateralAssetBalance);
    }

    function _validateImplementationCustodySnapshotAddress(address expectedImplementation, address actualImplementation)
        internal
        pure
    {
        if (actualImplementation != expectedImplementation) {
            revert UnexpectedImplementationCustodySnapshot(expectedImplementation, actualImplementation);
        }
    }

    function _validateImplementationCustodyUnchanged(
        LendingPoolV1_1UpgradeStateFingerprint.ConfigurationSnapshot memory config,
        LendingPoolV1_1UpgradeStateFingerprint.ImplementationCustodySnapshot memory expected
    ) internal view {
        _checkImplementationCustodyBalance(
            expected.implementation,
            config.collateralAsset,
            expected.collateralAssetBalance,
            _readBalance(config.collateralAsset, expected.implementation)
        );
        _checkImplementationCustodyBalance(
            expected.implementation,
            config.debtAsset,
            expected.debtAssetBalance,
            _readBalance(config.debtAsset, expected.implementation)
        );
        _checkImplementationCustodyBalance(
            expected.implementation,
            config.vault,
            expected.vaultShareBalance,
            _readBalance(config.vault, expected.implementation)
        );
    }

    function _checkImplementationCustodyBalance(
        address implementation,
        address asset,
        uint256 expectedBalance,
        uint256 actualBalance
    ) internal pure {
        if (actualBalance != expectedBalance) {
            revert ImplementationCustodyBalanceChanged(implementation, asset, expectedBalance, actualBalance);
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

    function _validateVersion(address implementation) internal pure {
        try LendingPoolV1_1(implementation).version() returns (string memory actualVersion) {
            if (keccak256(bytes(actualVersion)) != keccak256(bytes("1.1"))) {
                revert UnexpectedVersion(actualVersion);
            }
        } catch {
            revert VersionReadFailed(implementation);
        }
    }

    function _nextDeploymentAddress(address deploymentSender) internal view returns (address) {
        return vm.computeCreateAddress(deploymentSender, vm.getNonce(deploymentSender));
    }

    function _broadcastSender() internal returns (address broadcastSender) {
        (, broadcastSender,) = vm.readCallers();
    }

    function _readProxyAddress(address proxy, bytes4 selector) internal view returns (address) {
        uint256 value = uint256(_readProxyWord(proxy, selector));
        if (value > type(uint160).max) {
            revert LendingPoolProxyInterfaceReadFailed(proxy, selector);
        }
        // The preceding upper-bound check proves this conversion cannot truncate non-zero upper bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(value));
    }

    function _readProxyUint(address proxy, bytes4 selector) internal view returns (uint256) {
        return uint256(_readProxyWord(proxy, selector));
    }

    function _readProxyWord(address proxy, bytes4 selector) internal view returns (bytes32 word) {
        (bool success, bytes memory returnData) = proxy.staticcall(abi.encodeWithSelector(selector));
        if (!success || returnData.length != 32) {
            revert LendingPoolProxyInterfaceReadFailed(proxy, selector);
        }
        word = abi.decode(returnData, (bytes32));
    }

    function _readBalance(address token, address account) internal view returns (uint256) {
        return _readExternalUint(token, abi.encodeCall(IERC20.balanceOf, (account)));
    }

    function _readExternalUint(address target, bytes memory callData) internal view returns (uint256 value) {
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(callData, 0x20))
        }

        (bool success, bytes memory returnData) = target.staticcall(callData);
        if (!success || returnData.length != 32) {
            revert SnapshotReadFailed(target, selector);
        }
        value = abi.decode(returnData, (uint256));
    }

    function _checkAddress(bytes32 field, address expected, address actual) internal pure {
        _checkBytes32(field, _addressWord(expected), _addressWord(actual));
    }

    function _checkUint(bytes32 field, uint256 expected, uint256 actual) internal pure {
        _checkBytes32(field, bytes32(expected), bytes32(actual));
    }

    function _checkBytes32(bytes32 field, bytes32 expected, bytes32 actual) internal pure {
        if (expected != actual) {
            revert SnapshotValueChanged(field, expected, actual);
        }
    }

    function _addressWord(address value) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    function _readUpgradeConfig() internal view returns (UpgradeConfig memory config) {
        config = UpgradeConfig({
            lendingPoolProxy: vm.envAddress("LENDING_POOL_PROXY"),
            expectedCurrentImplementation: vm.envAddress("EXPECTED_V1_IMPLEMENTATION"),
            expectedUpgradeAuthority: vm.envAddress("EXPECTED_UPGRADE_AUTHORITY"),
            expectedPendingUpgradeAuthority: vm.envAddress("EXPECTED_PENDING_UPGRADE_AUTHORITY"),
            expectedChainId: vm.envUint("EXPECTED_CHAIN_ID")
        });
    }

    function _logPreparation(PreparedTransaction memory prepared) internal view {
        console2.log("Chain ID:", block.chainid);
        console2.log("LendingPool proxy:", prepared.proxy);
        console2.log("Expected current implementation:", prepared.expectedCurrentImplementation);
        console2.log("New implementation:", prepared.newImplementation);
        console2.log("Expected upgrade authority:", prepared.expectedUpgradeAuthority);
        console2.log("Target:", prepared.target);
        console2.log("Value:", prepared.value);
        console2.log("Calldata:");
        console2.logBytes(prepared.data);
        console2.log("Pre-upgrade state hash:");
        console2.logBytes32(prepared.preUpgradeStateHash);
    }
}
