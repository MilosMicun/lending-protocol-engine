// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LendingPool} from "../src/core/lending/LendingPool.sol";
import {
    ILendingPoolSnapshotView,
    LendingPoolV1_1UpgradeStateFingerprint,
    UpgradeLendingPoolV1_1
} from "./UpgradeLendingPoolV1_1.s.sol";

interface ILendingPoolV1_1VersionView {
    function version() external pure returns (string memory);
}

contract VerifyLendingPoolV1_1Upgrade is Script {
    struct VerificationConfig {
        uint256 expectedChainId;
        address lendingPoolProxy;
        address expectedOldImplementation;
        address expectedNewImplementation;
        address expectedUpgradeAuthority;
        address expectedPendingUpgradeAuthority;
        bytes32 expectedPreUpgradeStateHash;
    }

    error UnexpectedChainId(uint256 expectedChainId, uint256 actualChainId);
    error InvalidAddress(bytes32 field, address actualAddress);
    error AddressHasNoCode(bytes32 field, address actualAddress);
    error ExpectedAddressesNotDistinct(address proxy, address oldImplementation, address newImplementation);
    error UnexpectedCurrentImplementation(bytes32 expectedImplementationWord, bytes32 actualImplementationWord);
    error OldImplementationStillActive(bytes32 oldImplementationWord, bytes32 actualImplementationWord);
    error ProxiableUUIDReadFailed(address implementation);
    error UnexpectedProxiableUUID(address implementation, bytes32 expectedUuid, bytes32 actualUuid);
    error VersionReadFailed(address proxy);
    error UnexpectedVersion(string expectedVersion, string actualVersion);
    error ProxyInterfaceReadFailed(address proxy, bytes4 selector);
    error SnapshotReadFailed(address target, bytes4 selector);
    error UnexpectedActiveUpgradeAuthority(address expectedAuthority, address actualAuthority);
    error UnexpectedPendingUpgradeAuthority(address expectedAuthority, address actualAuthority);
    error StateFingerprintMismatch(bytes32 expectedStateHash, bytes32 actualStateHash);

    bytes32 public constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external view returns (bytes32 verifiedStateHash) {
        VerificationConfig memory config = _readVerificationConfig();
        string memory verifiedVersion;
        (verifiedStateHash, verifiedVersion) = verify(config);

        console2.log("Chain ID:", block.chainid);
        console2.log("LendingPool proxy:", config.lendingPoolProxy);
        console2.log("Old implementation:", config.expectedOldImplementation);
        console2.log("New implementation:", config.expectedNewImplementation);
        console2.log("Active upgrade authority:", config.expectedUpgradeAuthority);
        console2.log("Pending upgrade authority:", config.expectedPendingUpgradeAuthority);
        console2.log("Verified state hash:");
        console2.logBytes32(verifiedStateHash);
        console2.log("Version:", verifiedVersion);
    }

    function verify(VerificationConfig memory config)
        public
        view
        returns (bytes32 verifiedStateHash, string memory verifiedVersion)
    {
        if (config.expectedChainId != block.chainid) {
            revert UnexpectedChainId(config.expectedChainId, block.chainid);
        }

        _validateContractAddress("proxy", config.lendingPoolProxy);
        _validateContractAddress("oldImplementation", config.expectedOldImplementation);
        _validateContractAddress("newImplementation", config.expectedNewImplementation);
        if (
            config.lendingPoolProxy == config.expectedOldImplementation
                || config.lendingPoolProxy == config.expectedNewImplementation
                || config.expectedOldImplementation == config.expectedNewImplementation
        ) {
            revert ExpectedAddressesNotDistinct(
                config.lendingPoolProxy, config.expectedOldImplementation, config.expectedNewImplementation
            );
        }

        bytes32 implementationWord = vm.load(config.lendingPoolProxy, ERC1967_IMPLEMENTATION_SLOT);
        bytes32 expectedNewImplementationWord = _addressWord(config.expectedNewImplementation);
        if (implementationWord != expectedNewImplementationWord) {
            revert UnexpectedCurrentImplementation(expectedNewImplementationWord, implementationWord);
        }
        bytes32 oldImplementationWord = _addressWord(config.expectedOldImplementation);
        if (implementationWord == oldImplementationWord) {
            revert OldImplementationStillActive(oldImplementationWord, implementationWord);
        }

        _validateProxiableUuid(config.expectedNewImplementation);
        verifiedVersion = _readVersion(config.lendingPoolProxy);
        if (keccak256(bytes(verifiedVersion)) != keccak256(bytes("1.1"))) {
            revert UnexpectedVersion("1.1", verifiedVersion);
        }

        UpgradeLendingPoolV1_1.UpgradeSnapshot memory state = snapshot(config.lendingPoolProxy);
        if (state.activeUpgradeAuthority != config.expectedUpgradeAuthority) {
            revert UnexpectedActiveUpgradeAuthority(config.expectedUpgradeAuthority, state.activeUpgradeAuthority);
        }
        if (state.pendingUpgradeAuthority != config.expectedPendingUpgradeAuthority) {
            revert UnexpectedPendingUpgradeAuthority(
                config.expectedPendingUpgradeAuthority, state.pendingUpgradeAuthority
            );
        }

        LendingPoolV1_1UpgradeStateFingerprint.ImplementationCustodySnapshot memory oldImplementationCustody =
            snapshotImplementationCustody(state.configuration, config.expectedOldImplementation);
        LendingPoolV1_1UpgradeStateFingerprint.ImplementationCustodySnapshot memory newImplementationCustody =
            snapshotImplementationCustody(state.configuration, config.expectedNewImplementation);

        verifiedStateHash = LendingPoolV1_1UpgradeStateFingerprint.calculate(
            LendingPoolV1_1UpgradeStateFingerprint.State({
                chainId: block.chainid,
                proxy: state.lendingPoolProxy,
                expectedOldImplementation: config.expectedOldImplementation,
                expectedNewImplementation: config.expectedNewImplementation,
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
        if (verifiedStateHash != config.expectedPreUpgradeStateHash) {
            revert StateFingerprintMismatch(config.expectedPreUpgradeStateHash, verifiedStateHash);
        }
    }

    function snapshot(address lendingPoolProxy)
        public
        view
        returns (UpgradeLendingPoolV1_1.UpgradeSnapshot memory state)
    {
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
        custody.proxyCollateralAssetBalance = _readBalance(config.collateralAsset, proxy);
        custody.proxyDebtAssetBalance = _readBalance(config.debtAsset, proxy);
        custody.proxyVaultShareBalance = _readBalance(config.vault, proxy);
        custody.vaultTotalAssets = _readExternalUint(config.vault, abi.encodeWithSignature("totalAssets()"));
        custody.vaultTotalSupply = _readExternalUint(config.vault, abi.encodeWithSignature("totalSupply()"));
        custody.vaultCollateralAssetBalance = _readBalance(config.collateralAsset, config.vault);
    }

    function _validateContractAddress(bytes32 field, address account) internal view {
        if (account == address(0)) {
            revert InvalidAddress(field, account);
        }
        if (account.code.length == 0) {
            revert AddressHasNoCode(field, account);
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
            revert UnexpectedProxiableUUID(implementation, ERC1967_IMPLEMENTATION_SLOT, uuid);
        }
    }

    function _readVersion(address proxy) internal pure returns (string memory actualVersion) {
        try ILendingPoolV1_1VersionView(proxy).version() returns (string memory versionValue) {
            return versionValue;
        } catch {
            revert VersionReadFailed(proxy);
        }
    }

    function _readProxyAddress(address proxy, bytes4 selector) internal view returns (address) {
        uint256 value = uint256(_readProxyWord(proxy, selector));
        if (value > type(uint160).max) {
            revert ProxyInterfaceReadFailed(proxy, selector);
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
            revert ProxyInterfaceReadFailed(proxy, selector);
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

    function _addressWord(address value) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    function _readVerificationConfig() internal view returns (VerificationConfig memory config) {
        config = VerificationConfig({
            expectedChainId: vm.envUint("EXPECTED_CHAIN_ID"),
            lendingPoolProxy: vm.envAddress("LENDING_POOL_PROXY"),
            expectedOldImplementation: vm.envAddress("EXPECTED_OLD_IMPLEMENTATION"),
            expectedNewImplementation: vm.envAddress("EXPECTED_NEW_IMPLEMENTATION"),
            expectedUpgradeAuthority: vm.envAddress("EXPECTED_UPGRADE_AUTHORITY"),
            expectedPendingUpgradeAuthority: vm.envAddress("EXPECTED_PENDING_UPGRADE_AUTHORITY"),
            expectedPreUpgradeStateHash: vm.envBytes32("EXPECTED_PRE_UPGRADE_STATE_HASH")
        });
    }
}
