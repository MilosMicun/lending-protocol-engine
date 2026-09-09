// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LendingPool} from "../src/core/lending/LendingPool.sol";
import {LendingPoolV1_2} from "../src/core/lending/LendingPoolV1_2.sol";

interface ILendingPoolV1_2SnapshotView {
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
    function scaledDebtOf(address account) external view returns (uint256);
    function collateralSharesOf(address account) external view returns (uint256);
    function liquidityBalanceOf(address account) external view returns (uint256);
}

/// @notice Canonical evidence captured before a V1.2 upgrade.
/// @dev The hash is verification input, not a proxy-transaction guard. Operators must run a fresh preflight
///      immediately before Safe execution because state may change after preparation.
library LendingPoolV1_2UpgradeStateFingerprint {
    bytes32 internal constant DOMAIN_SEPARATOR = keccak256("LendingPoolV1.2UpgradeStateFingerprint/v2");

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
        uint256 proxyCollateralAssetBalance;
        uint256 proxyDebtAssetBalance;
        uint256 proxyVaultShareBalance;
        uint256 vaultTotalAssets;
        uint256 vaultTotalSupply;
        uint256 vaultCollateralAssetBalance;
    }

    /// @dev Permissionless token transfers can create these balances. They are incidental balances, not protocol custody.
    struct ImplementationBalanceSnapshot {
        address implementation;
        uint256 collateralAssetBalance;
        uint256 debtAssetBalance;
        uint256 vaultShareBalance;
    }

    struct TrackedAccountSnapshot {
        address account;
        uint256 scaledDebt;
        uint256 collateralShares;
        uint256 liquidityBalance;
    }

    struct State {
        uint256 chainId;
        address proxy;
        address oldImplementation;
        address newImplementation;
        bytes32 newImplementationCodeHash;
        bytes32[18] protocolSlots;
        bytes32 initializableNamespace;
        address activeUpgradeAuthority;
        address pendingUpgradeAuthority;
        ConfigurationSnapshot configuration;
        AccountingSnapshot accounting;
        CustodySnapshot custody;
        bool trackedAccountSetIsComplete;
        TrackedAccountSnapshot[] trackedAccounts;
        ImplementationBalanceSnapshot oldImplementationBalances;
        ImplementationBalanceSnapshot newImplementationBalances;
    }

    function calculate(State memory state) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_SEPARATOR, state));
    }
}

/// @notice Domain-separated record of one authentic typed-construction preparation output.
/// @dev The digest is not a signature, Safe transaction hash, or on-chain attestation. Its provenance depends on the
///      operator preserving the authentic preparation output through an independent trusted channel or artifact.
library LendingPoolV1_2PreparationAttestation {
    bytes32 internal constant DOMAIN_SEPARATOR = keccak256("LendingPoolV1.2PreparationAttestation/v1");
    bytes32 internal constant PAYLOAD_FINGERPRINT_DOMAIN = keccak256("LendingPoolV1.2PreparedSafeTransaction/v1");
    uint256 internal constant FORMAT_VERSION = 1;

    struct Attestation {
        uint256 formatVersion;
        uint256 chainId;
        address proxy;
        address expectedContractUpgradeAuthority;
        address expectedPendingUpgradeAuthority;
        address oldImplementation;
        address newImplementation;
        bytes32 newImplementationCodeHash;
        bytes32 trackedAccountCommitment;
        bytes32 preUpgradeStateHash;
        address target;
        uint256 value;
        bytes data;
        bytes32 payloadFingerprint;
    }

    function calculate(Attestation memory attestation) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_SEPARATOR, attestation));
    }

    function formatVersion() internal pure returns (uint256) {
        return FORMAT_VERSION;
    }

    function calculatePayloadFingerprint(
        uint256 chainId,
        address expectedContractUpgradeAuthority,
        address target,
        uint256 value,
        bytes memory data
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(PAYLOAD_FINGERPRINT_DOMAIN, chainId, expectedContractUpgradeAuthority, target, value, data)
        );
    }
}

contract UpgradeLendingPoolV1_2 is Script {
    struct UpgradeConfig {
        uint256 expectedChainId;
        address lendingPoolProxy;
        address expectedCurrentImplementation;
        address expectedContractUpgradeAuthority;
        address expectedPendingUpgradeAuthority;
        bool trackedAccountSetIsComplete;
        address[] trackedAccounts;
    }

    // Mapping storage cannot be enumerated on-chain. The operator must derive the canonical sorted account list
    // from authenticated deployment and interaction evidence. This tooling proves continuity only for that list;
    // it does not claim to enumerate arbitrary mapping storage. Exact authenticated implementation bytecode plus
    // separately reviewed migration logic provides the remaining implementation guarantee. When
    // `trackedAccountSetIsComplete` is true, checked sums must equal all three aggregate accounting totals.

    struct ProxySnapshot {
        address lendingPoolProxy;
        bytes32 implementationWord;
        bytes32[18] protocolSlots;
        bytes32 initializableNamespace;
        address activeUpgradeAuthority;
        address pendingUpgradeAuthority;
        LendingPoolV1_2UpgradeStateFingerprint.ConfigurationSnapshot configuration;
        LendingPoolV1_2UpgradeStateFingerprint.AccountingSnapshot accounting;
        LendingPoolV1_2UpgradeStateFingerprint.CustodySnapshot custody;
        LendingPoolV1_2UpgradeStateFingerprint.TrackedAccountSnapshot[] trackedAccounts;
    }

    struct PreparedTransaction {
        address proxy;
        address expectedCurrentImplementation;
        address newImplementation;
        bytes32 newImplementationCodeHash;
        address expectedContractUpgradeAuthority;
        address expectedPendingUpgradeAuthority;
        address target;
        uint256 value;
        bytes data;
        bytes32 preUpgradeStateHash;
        bytes32 payloadFingerprint;
        bytes32 trackedAccountCommitment;
        bytes32 preparationAttestationDigest;
        LendingPoolV1_2UpgradeStateFingerprint.State preUpgradeState;
    }

    error InvalidLendingPoolProxy(address proxy);
    error LendingPoolProxyHasNoCode(address proxy);
    error InvalidExpectedCurrentImplementation(address implementation);
    error ExpectedCurrentImplementationHasNoCode(address implementation);
    error InvalidExpectedContractUpgradeAuthority(address authority);
    error ExpectedContractUpgradeAuthorityHasNoCode(address authority);
    error UnexpectedChainId(uint256 expected, uint256 actual);
    error UnexpectedCurrentImplementation(bytes32 expected, bytes32 actual);
    error UnexpectedActiveUpgradeAuthority(address expected, address actual);
    error UnexpectedPendingUpgradeAuthority(address expected, address actual);
    error ProxiableUUIDReadFailed(address implementation);
    error UnexpectedProxiableUUID(address implementation, bytes32 actualUuid);
    error ProxyInterfaceReadFailed(address proxy, bytes4 selector);
    error SnapshotReadFailed(address target, bytes4 selector);
    error NewImplementationHasNoCode(address implementation);
    error NewImplementationMatchesProxy(address implementation);
    error NewImplementationMatchesCurrentImplementation(address implementation);
    error VersionReadFailed(address implementation);
    error UnexpectedVersion(string actualVersion);
    error ImplementationInitializersNotLocked(address implementation, bytes32 initializableWord);
    error CandidateCodeHashChanged(bytes32 deployedCodeHash, bytes32 currentCodeHash);
    error UnexpectedProxyInitializationState(bytes32 initializableWord);
    error ProxyStateChanged(bytes32 field, bytes32 expected, bytes32 actual);
    error UnexpectedImplementationBalanceSnapshot(address expected, address actual);
    error ImplementationIncidentalBalanceChanged(
        address implementation, address asset, uint256 expected, uint256 actual
    );
    error InvalidTrackedAccount(uint256 index, address account);
    error TrackedAccountsNotStrictlySorted(uint256 index, address previous, address account);
    error TrackedAccountTotalsMismatch(bytes32 field, uint256 expected, uint256 actual);
    error IncorrectPreparedTarget(address expected, address actual);
    error NonzeroPreparedValue(uint256 actual);
    error IncorrectOuterSelector(bytes4 expected, bytes4 actual);
    error TruncatedOuterCalldata(uint256 minimum, uint256 actual);
    error IncorrectOuterCalldataLength(uint256 expected, uint256 actual);
    error NonCanonicalDynamicOffset(uint256 expected, uint256 actual);
    error NonCanonicalImplementationWord(bytes32 actual);
    error NonzeroCanonicalPadding(uint256 index, bytes1 actual);
    error NonCanonicalPreparedCalldata();
    error PayloadImplementationMismatch(address expected, address actual);
    error EmptyMigrationCalldata();
    error IncorrectInnerCalldataLength(uint256 expected, uint256 actual);
    error IncorrectInnerSelector(bytes4 expected, bytes4 actual);

    bytes32 public constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 public constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 public constant PAYLOAD_FINGERPRINT_DOMAIN = keccak256("LendingPoolV1.2PreparedSafeTransaction/v1");

    /// @notice Deploys only the implementation, then performs read-only validation and preparation.
    /// @dev This never broadcasts a proxy call, migration, Safe proposal, signature, or Safe execution.
    function run() external returns (PreparedTransaction memory preparedSafeTransaction) {
        UpgradeConfig memory config = _readUpgradeConfig();
        validatePreUpgrade(config);
        ProxySnapshot memory beforeDeployment = snapshot(config.lendingPoolProxy, config.trackedAccounts);
        LendingPoolV1_2UpgradeStateFingerprint.ImplementationBalanceSnapshot memory oldBalances =
            snapshotImplementationBalances(beforeDeployment.configuration, config.expectedCurrentImplementation);

        address predictedImplementation = _nextDeploymentAddress(_broadcastSender());
        LendingPoolV1_2UpgradeStateFingerprint.ImplementationBalanceSnapshot memory newBalances =
            snapshotImplementationBalances(beforeDeployment.configuration, predictedImplementation);

        vm.startBroadcast();
        LendingPoolV1_2 newImplementation = new LendingPoolV1_2();
        vm.stopBroadcast();
        // Broadcast boundary ends above. Everything below is read-only.
        bytes32 candidateCodeHash = address(newImplementation).codehash;

        preparedSafeTransaction = _validateAndPrepare(
            config, beforeDeployment, address(newImplementation), candidateCodeHash, oldBalances, newBalances
        );
        _logPreparation(preparedSafeTransaction);
    }

    /// @notice Non-broadcast local preparation path used by tests and offline rehearsal.
    function prepare(UpgradeConfig memory config) public returns (PreparedTransaction memory preparedSafeTransaction) {
        validatePreUpgrade(config);
        ProxySnapshot memory beforeDeployment = snapshot(config.lendingPoolProxy, config.trackedAccounts);
        LendingPoolV1_2UpgradeStateFingerprint.ImplementationBalanceSnapshot memory oldBalances =
            snapshotImplementationBalances(beforeDeployment.configuration, config.expectedCurrentImplementation);
        address predictedImplementation = _nextDeploymentAddress(address(this));
        LendingPoolV1_2UpgradeStateFingerprint.ImplementationBalanceSnapshot memory newBalances =
            snapshotImplementationBalances(beforeDeployment.configuration, predictedImplementation);

        LendingPoolV1_2 newImplementation = new LendingPoolV1_2();
        bytes32 candidateCodeHash = address(newImplementation).codehash;
        preparedSafeTransaction = _validateAndPrepare(
            config, beforeDeployment, address(newImplementation), candidateCodeHash, oldBalances, newBalances
        );
    }

    function validateConfig(UpgradeConfig memory config) public view {
        if (config.expectedChainId != block.chainid) revert UnexpectedChainId(config.expectedChainId, block.chainid);
        if (config.lendingPoolProxy == address(0)) revert InvalidLendingPoolProxy(config.lendingPoolProxy);
        if (config.expectedCurrentImplementation == address(0)) {
            revert InvalidExpectedCurrentImplementation(config.expectedCurrentImplementation);
        }
        if (config.expectedContractUpgradeAuthority == address(0)) {
            revert InvalidExpectedContractUpgradeAuthority(config.expectedContractUpgradeAuthority);
        }
        if (config.expectedContractUpgradeAuthority.code.length == 0) {
            revert ExpectedContractUpgradeAuthorityHasNoCode(config.expectedContractUpgradeAuthority);
        }
        _validateTrackedAccounts(config.trackedAccounts);
    }

    function validatePreUpgrade(UpgradeConfig memory config) public view {
        validateConfig(config);
        if (config.lendingPoolProxy.code.length == 0) revert LendingPoolProxyHasNoCode(config.lendingPoolProxy);
        if (config.expectedCurrentImplementation.code.length == 0) {
            revert ExpectedCurrentImplementationHasNoCode(config.expectedCurrentImplementation);
        }

        bytes32 actualImplementation = vm.load(config.lendingPoolProxy, ERC1967_IMPLEMENTATION_SLOT);
        bytes32 expectedImplementation = _addressWord(config.expectedCurrentImplementation);
        if (actualImplementation != expectedImplementation) {
            revert UnexpectedCurrentImplementation(expectedImplementation, actualImplementation);
        }
        _validateProxiableUuid(config.expectedCurrentImplementation);

        address active = _readProxyAddress(config.lendingPoolProxy, LendingPool.upgradeAuthority.selector);
        if (active != config.expectedContractUpgradeAuthority) {
            revert UnexpectedActiveUpgradeAuthority(config.expectedContractUpgradeAuthority, active);
        }
        address pending = _readProxyAddress(config.lendingPoolProxy, LendingPool.pendingUpgradeAuthority.selector);
        if (pending != config.expectedPendingUpgradeAuthority) {
            revert UnexpectedPendingUpgradeAuthority(config.expectedPendingUpgradeAuthority, pending);
        }
        bytes32 initializableWord = vm.load(config.lendingPoolProxy, INITIALIZABLE_STORAGE);
        uint256 rawInitializable = uint256(initializableWord);
        if ((rawInitializable & type(uint64).max) != 1 || ((rawInitializable >> 64) & 0xff) != 0) {
            revert UnexpectedProxyInitializationState(initializableWord);
        }
        ProxySnapshot memory state = snapshot(config.lendingPoolProxy, config.trackedAccounts);
        if (config.trackedAccountSetIsComplete) _validateTrackedTotals(state.accounting, state.trackedAccounts);
    }

    function snapshot(address proxy, address[] memory trackedAccounts)
        public
        view
        returns (ProxySnapshot memory state)
    {
        state.lendingPoolProxy = proxy;
        state.implementationWord = vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT);
        state.initializableNamespace = vm.load(proxy, INITIALIZABLE_STORAGE);
        state.activeUpgradeAuthority = _readProxyAddress(proxy, LendingPool.upgradeAuthority.selector);
        state.pendingUpgradeAuthority = _readProxyAddress(proxy, LendingPool.pendingUpgradeAuthority.selector);
        for (uint256 slot; slot < state.protocolSlots.length; ++slot) {
            state.protocolSlots[slot] = vm.load(proxy, bytes32(slot));
        }
        state.configuration = _snapshotConfiguration(proxy);
        state.accounting = _snapshotAccounting(proxy);
        state.custody = _snapshotCustody(proxy, state.configuration);
        state.trackedAccounts = _snapshotTrackedAccounts(proxy, trackedAccounts);
    }

    function snapshotImplementationBalances(
        LendingPoolV1_2UpgradeStateFingerprint.ConfigurationSnapshot memory config,
        address implementation
    ) public view returns (LendingPoolV1_2UpgradeStateFingerprint.ImplementationBalanceSnapshot memory balances) {
        balances.implementation = implementation;
        balances.collateralAssetBalance = _readBalance(config.collateralAsset, implementation);
        balances.debtAssetBalance = _readBalance(config.debtAsset, implementation);
        balances.vaultShareBalance = _readBalance(config.vault, implementation);
    }

    function encodeUpgradeCall(address newImplementation) public pure returns (bytes memory) {
        bytes memory migration = abi.encodeCall(LendingPoolV1_2.migrateToV1_2, ());
        return abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, newImplementation, migration);
    }

    function calculatePayloadFingerprint(
        uint256 chainId,
        address expectedContractUpgradeAuthority,
        address target,
        uint256 value,
        bytes memory data
    ) public pure returns (bytes32) {
        return LendingPoolV1_2PreparationAttestation.calculatePayloadFingerprint(
            chainId, expectedContractUpgradeAuthority, target, value, data
        );
    }

    function calculateStateFingerprint(LendingPoolV1_2UpgradeStateFingerprint.State memory state)
        public
        pure
        returns (bytes32)
    {
        return LendingPoolV1_2UpgradeStateFingerprint.calculate(state);
    }

    function validatePreparedSafeTransaction(
        address expectedProxy,
        address expectedContractUpgradeAuthority,
        address validatedNewImplementation,
        address target,
        uint256 value,
        bytes memory data
    ) public view {
        if (target != expectedProxy) revert IncorrectPreparedTarget(expectedProxy, target);
        if (value != 0) revert NonzeroPreparedValue(value);
        if (expectedContractUpgradeAuthority.code.length == 0) {
            revert ExpectedContractUpgradeAuthorityHasNoCode(expectedContractUpgradeAuthority);
        }

        bytes4 outerSelector;
        if (data.length >= 4) {
            assembly ("memory-safe") {
                outerSelector := mload(add(data, 0x20))
            }
        }
        if (outerSelector != UUPSUpgradeable.upgradeToAndCall.selector) {
            revert IncorrectOuterSelector(UUPSUpgradeable.upgradeToAndCall.selector, outerSelector);
        }
        if (data.length < 100) revert TruncatedOuterCalldata(100, data.length);

        bytes32 implementationWord;
        uint256 dynamicOffset;
        uint256 innerLength;
        assembly ("memory-safe") {
            implementationWord := mload(add(data, 0x24))
            dynamicOffset := mload(add(data, 0x44))
            innerLength := mload(add(data, 0x64))
        }
        if (uint256(implementationWord) > type(uint160).max) {
            revert NonCanonicalImplementationWord(implementationWord);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        address encodedImplementation = address(uint160(uint256(implementationWord)));
        if (encodedImplementation != validatedNewImplementation) {
            revert PayloadImplementationMismatch(validatedNewImplementation, encodedImplementation);
        }
        if (dynamicOffset != 64) revert NonCanonicalDynamicOffset(64, dynamicOffset);
        if (innerLength == 0) revert EmptyMigrationCalldata();
        if (innerLength != 4) revert IncorrectInnerCalldataLength(4, innerLength);
        if (data.length < 132) revert TruncatedOuterCalldata(132, data.length);
        bytes4 innerSelector;
        assembly ("memory-safe") {
            innerSelector := mload(add(data, 0x84))
        }
        if (innerSelector != LendingPoolV1_2.migrateToV1_2.selector) {
            revert IncorrectInnerSelector(LendingPoolV1_2.migrateToV1_2.selector, innerSelector);
        }
        for (uint256 i = 104; i < 132; ++i) {
            if (data[i] != bytes1(0)) revert NonzeroCanonicalPadding(i, data[i]);
        }
        bytes memory canonical = encodeUpgradeCall(validatedNewImplementation);
        if (data.length != canonical.length) revert IncorrectOuterCalldataLength(canonical.length, data.length);
        if (keccak256(data) != keccak256(canonical)) revert NonCanonicalPreparedCalldata();
    }

    function _validateAndPrepare(
        UpgradeConfig memory config,
        ProxySnapshot memory beforePreparation,
        address newImplementation,
        bytes32 candidateCodeHash,
        LendingPoolV1_2UpgradeStateFingerprint.ImplementationBalanceSnapshot memory oldBalances,
        LendingPoolV1_2UpgradeStateFingerprint.ImplementationBalanceSnapshot memory newBalances
    ) internal view returns (PreparedTransaction memory prepared) {
        _validateNewImplementation(config, newImplementation);
        // UUPS embeds `__self` as an immutable, so runtime hashes from separate deployment addresses are not assumed
        // equal even when both were created from the same source. Preserve the exact post-construction hash instead.
        if (newImplementation.codehash != candidateCodeHash) {
            revert CandidateCodeHashChanged(candidateCodeHash, newImplementation.codehash);
        }
        validatePreUpgrade(config);
        _validatePreservedProxyState(beforePreparation);
        _validateImplementationBalanceAddress(config.expectedCurrentImplementation, oldBalances.implementation);
        _validateImplementationBalanceAddress(newImplementation, newBalances.implementation);
        _validateImplementationBalancesUnchanged(beforePreparation.configuration, oldBalances);
        _validateImplementationBalancesUnchanged(beforePreparation.configuration, newBalances);

        LendingPoolV1_2UpgradeStateFingerprint.State memory preState = LendingPoolV1_2UpgradeStateFingerprint.State({
            chainId: config.expectedChainId,
            proxy: config.lendingPoolProxy,
            oldImplementation: config.expectedCurrentImplementation,
            newImplementation: newImplementation,
            newImplementationCodeHash: candidateCodeHash,
            protocolSlots: beforePreparation.protocolSlots,
            initializableNamespace: beforePreparation.initializableNamespace,
            activeUpgradeAuthority: beforePreparation.activeUpgradeAuthority,
            pendingUpgradeAuthority: beforePreparation.pendingUpgradeAuthority,
            configuration: beforePreparation.configuration,
            accounting: beforePreparation.accounting,
            custody: beforePreparation.custody,
            trackedAccountSetIsComplete: config.trackedAccountSetIsComplete,
            trackedAccounts: beforePreparation.trackedAccounts,
            oldImplementationBalances: oldBalances,
            newImplementationBalances: newBalances
        });
        bytes memory data = encodeUpgradeCall(newImplementation);
        validatePreparedSafeTransaction(
            config.lendingPoolProxy,
            config.expectedContractUpgradeAuthority,
            newImplementation,
            config.lendingPoolProxy,
            0,
            data
        );

        bytes32 preUpgradeStateHash = LendingPoolV1_2UpgradeStateFingerprint.calculate(preState);
        bytes32 payloadFingerprint = calculatePayloadFingerprint(
            config.expectedChainId, config.expectedContractUpgradeAuthority, config.lendingPoolProxy, 0, data
        );
        bytes32 trackedAccountCommitment = keccak256(abi.encode(config.trackedAccounts));
        bytes32 preparationAttestationDigest = LendingPoolV1_2PreparationAttestation.calculate(
            LendingPoolV1_2PreparationAttestation.Attestation({
                formatVersion: LendingPoolV1_2PreparationAttestation.formatVersion(),
                chainId: config.expectedChainId,
                proxy: config.lendingPoolProxy,
                expectedContractUpgradeAuthority: config.expectedContractUpgradeAuthority,
                expectedPendingUpgradeAuthority: config.expectedPendingUpgradeAuthority,
                oldImplementation: config.expectedCurrentImplementation,
                newImplementation: newImplementation,
                newImplementationCodeHash: candidateCodeHash,
                trackedAccountCommitment: trackedAccountCommitment,
                preUpgradeStateHash: preUpgradeStateHash,
                target: config.lendingPoolProxy,
                value: 0,
                data: data,
                payloadFingerprint: payloadFingerprint
            })
        );

        prepared = PreparedTransaction({
            proxy: config.lendingPoolProxy,
            expectedCurrentImplementation: config.expectedCurrentImplementation,
            newImplementation: newImplementation,
            newImplementationCodeHash: candidateCodeHash,
            expectedContractUpgradeAuthority: config.expectedContractUpgradeAuthority,
            expectedPendingUpgradeAuthority: config.expectedPendingUpgradeAuthority,
            target: config.lendingPoolProxy,
            value: 0,
            data: data,
            preUpgradeStateHash: preUpgradeStateHash,
            payloadFingerprint: payloadFingerprint,
            trackedAccountCommitment: trackedAccountCommitment,
            preparationAttestationDigest: preparationAttestationDigest,
            preUpgradeState: preState
        });
    }

    function _validateNewImplementation(UpgradeConfig memory config, address implementation) internal view {
        if (implementation.code.length == 0) revert NewImplementationHasNoCode(implementation);
        if (implementation == config.lendingPoolProxy) revert NewImplementationMatchesProxy(implementation);
        if (implementation == config.expectedCurrentImplementation) {
            revert NewImplementationMatchesCurrentImplementation(implementation);
        }
        _validateProxiableUuid(implementation);
        _validateVersion(implementation);
        _validateImplementationInitializersLocked(implementation);
    }

    function _validateImplementationInitializersLocked(address implementation) internal view {
        bytes32 word = vm.load(implementation, INITIALIZABLE_STORAGE);
        uint256 raw = uint256(word);
        if ((raw & type(uint64).max) != type(uint64).max || ((raw >> 64) & 0xff) != 0) {
            revert ImplementationInitializersNotLocked(implementation, word);
        }
        (bool success, bytes memory result) =
            implementation.staticcall(abi.encodeCall(LendingPoolV1_2.migrateToV1_2, ()));
        // The length guard makes this selector conversion safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (success || result.length < 4 || bytes4(result) != Initializable.InvalidInitialization.selector) {
            revert ImplementationInitializersNotLocked(implementation, word);
        }
    }

    function _validatePreservedProxyState(ProxySnapshot memory expected) internal view {
        address[] memory accounts = new address[](expected.trackedAccounts.length);
        for (uint256 i; i < accounts.length; ++i) {
            accounts[i] = expected.trackedAccounts[i].account;
        }
        ProxySnapshot memory actual = snapshot(expected.lendingPoolProxy, accounts);
        _check("implementation", expected.implementationWord, actual.implementationWord);
        _check("initializable", expected.initializableNamespace, actual.initializableNamespace);
        _check(
            "activeAuthority",
            _addressWord(expected.activeUpgradeAuthority),
            _addressWord(actual.activeUpgradeAuthority)
        );
        _check(
            "pendingAuthority",
            _addressWord(expected.pendingUpgradeAuthority),
            _addressWord(actual.pendingUpgradeAuthority)
        );
        for (uint256 slot; slot < expected.protocolSlots.length; ++slot) {
            _check(bytes32(slot), expected.protocolSlots[slot], actual.protocolSlots[slot]);
        }
        _check(
            "configuration", keccak256(abi.encode(expected.configuration)), keccak256(abi.encode(actual.configuration))
        );
        _check("accounting", keccak256(abi.encode(expected.accounting)), keccak256(abi.encode(actual.accounting)));
        _check("custody", keccak256(abi.encode(expected.custody)), keccak256(abi.encode(actual.custody)));
        _check(
            "trackedAccounts",
            keccak256(abi.encode(expected.trackedAccounts)),
            keccak256(abi.encode(actual.trackedAccounts))
        );
    }

    function _snapshotTrackedAccounts(address proxy, address[] memory accounts)
        internal
        view
        returns (LendingPoolV1_2UpgradeStateFingerprint.TrackedAccountSnapshot[] memory tracked)
    {
        tracked = new LendingPoolV1_2UpgradeStateFingerprint.TrackedAccountSnapshot[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            tracked[i] = LendingPoolV1_2UpgradeStateFingerprint.TrackedAccountSnapshot({
                account: account,
                scaledDebt: _readProxyUintWithAddress(
                    proxy, ILendingPoolV1_2SnapshotView.scaledDebtOf.selector, account
                ),
                collateralShares: _readProxyUintWithAddress(
                    proxy, ILendingPoolV1_2SnapshotView.collateralSharesOf.selector, account
                ),
                liquidityBalance: _readProxyUintWithAddress(
                    proxy, ILendingPoolV1_2SnapshotView.liquidityBalanceOf.selector, account
                )
            });
        }
    }

    function _validateTrackedAccounts(address[] memory accounts) internal pure {
        address previous;
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            if (account == address(0)) revert InvalidTrackedAccount(i, account);
            if (i != 0 && uint160(account) <= uint160(previous)) {
                revert TrackedAccountsNotStrictlySorted(i, previous, account);
            }
            previous = account;
        }
    }

    function _validateTrackedTotals(
        LendingPoolV1_2UpgradeStateFingerprint.AccountingSnapshot memory accounting,
        LendingPoolV1_2UpgradeStateFingerprint.TrackedAccountSnapshot[] memory tracked
    ) internal pure {
        uint256 scaledDebt;
        uint256 collateralShares;
        uint256 liquidityBalance;
        for (uint256 i; i < tracked.length; ++i) {
            scaledDebt += tracked[i].scaledDebt;
            collateralShares += tracked[i].collateralShares;
            liquidityBalance += tracked[i].liquidityBalance;
        }
        if (scaledDebt != accounting.totalScaledDebt) {
            revert TrackedAccountTotalsMismatch("totalScaledDebt", accounting.totalScaledDebt, scaledDebt);
        }
        if (collateralShares != accounting.totalCollateralShares) {
            revert TrackedAccountTotalsMismatch(
                "totalCollateralShares", accounting.totalCollateralShares, collateralShares
            );
        }
        if (liquidityBalance != accounting.totalLiquidity) {
            revert TrackedAccountTotalsMismatch("totalLiquidity", accounting.totalLiquidity, liquidityBalance);
        }
    }

    function _snapshotConfiguration(address proxy)
        internal
        view
        returns (LendingPoolV1_2UpgradeStateFingerprint.ConfigurationSnapshot memory config)
    {
        config.priceFeed = _readProxyAddress(proxy, ILendingPoolV1_2SnapshotView.priceFeed.selector);
        config.vault = _readProxyAddress(proxy, ILendingPoolV1_2SnapshotView.vault.selector);
        config.debtAsset = _readProxyAddress(proxy, ILendingPoolV1_2SnapshotView.debtAsset.selector);
        config.collateralAsset = _readProxyAddress(proxy, ILendingPoolV1_2SnapshotView.collateralAsset.selector);
        config.maxPriceStaleness = _readProxyUint(proxy, ILendingPoolV1_2SnapshotView.maxPriceStaleness.selector);
        config.ltvBps = _readProxyUint(proxy, ILendingPoolV1_2SnapshotView.ltvBps.selector);
        config.liquidationThresholdBps =
            _readProxyUint(proxy, ILendingPoolV1_2SnapshotView.liquidationThresholdBps.selector);
        config.liquidationBonusBps = _readProxyUint(proxy, ILendingPoolV1_2SnapshotView.liquidationBonusBps.selector);
        config.baseBorrowRate = _readProxyUint(proxy, ILendingPoolV1_2SnapshotView.baseBorrowRate.selector);
        config.borrowRateSlope = _readProxyUint(proxy, ILendingPoolV1_2SnapshotView.borrowRateSlope.selector);
    }

    function _snapshotAccounting(address proxy)
        internal
        view
        returns (LendingPoolV1_2UpgradeStateFingerprint.AccountingSnapshot memory accounting)
    {
        accounting.borrowIndex = _readProxyUint(proxy, ILendingPoolV1_2SnapshotView.borrowIndex.selector);
        accounting.lastBorrowIndexUpdate =
            _readProxyUint(proxy, ILendingPoolV1_2SnapshotView.lastBorrowIndexUpdate.selector);
        accounting.totalCollateralShares =
            _readProxyUint(proxy, ILendingPoolV1_2SnapshotView.totalCollateralShares.selector);
        accounting.totalLiquidity = _readProxyUint(proxy, ILendingPoolV1_2SnapshotView.totalLiquidity.selector);
        accounting.totalScaledDebt = _readProxyUint(proxy, ILendingPoolV1_2SnapshotView.totalScaledDebt.selector);
    }

    function _snapshotCustody(address proxy, LendingPoolV1_2UpgradeStateFingerprint.ConfigurationSnapshot memory config)
        internal
        view
        returns (LendingPoolV1_2UpgradeStateFingerprint.CustodySnapshot memory custody)
    {
        custody.proxyCollateralAssetBalance = _readBalance(config.collateralAsset, proxy);
        custody.proxyDebtAssetBalance = _readBalance(config.debtAsset, proxy);
        custody.proxyVaultShareBalance = _readBalance(config.vault, proxy);
        custody.vaultTotalAssets = _readExternalUint(config.vault, abi.encodeWithSignature("totalAssets()"));
        custody.vaultTotalSupply = _readExternalUint(config.vault, abi.encodeWithSignature("totalSupply()"));
        custody.vaultCollateralAssetBalance = _readBalance(config.collateralAsset, config.vault);
    }

    function _validateImplementationBalancesUnchanged(
        LendingPoolV1_2UpgradeStateFingerprint.ConfigurationSnapshot memory config,
        LendingPoolV1_2UpgradeStateFingerprint.ImplementationBalanceSnapshot memory expected
    ) internal view {
        _checkImplementationBalance(
            expected,
            config.collateralAsset,
            expected.collateralAssetBalance,
            _readBalance(config.collateralAsset, expected.implementation)
        );
        _checkImplementationBalance(
            expected,
            config.debtAsset,
            expected.debtAssetBalance,
            _readBalance(config.debtAsset, expected.implementation)
        );
        _checkImplementationBalance(
            expected, config.vault, expected.vaultShareBalance, _readBalance(config.vault, expected.implementation)
        );
    }

    function _checkImplementationBalance(
        LendingPoolV1_2UpgradeStateFingerprint.ImplementationBalanceSnapshot memory expected,
        address asset,
        uint256 expectedBalance,
        uint256 actualBalance
    ) internal pure {
        if (expectedBalance != actualBalance) {
            revert ImplementationIncidentalBalanceChanged(
                expected.implementation, asset, expectedBalance, actualBalance
            );
        }
    }

    function _validateImplementationBalanceAddress(address expected, address actual) internal pure {
        if (expected != actual) revert UnexpectedImplementationBalanceSnapshot(expected, actual);
    }

    function _validateProxiableUuid(address implementation) internal view {
        (bool success, bytes memory result) =
            implementation.staticcall(abi.encodeCall(IERC1822Proxiable.proxiableUUID, ()));
        if (!success || result.length != 32) revert ProxiableUUIDReadFailed(implementation);
        bytes32 uuid = abi.decode(result, (bytes32));
        if (uuid != ERC1967_IMPLEMENTATION_SLOT) revert UnexpectedProxiableUUID(implementation, uuid);
    }

    function validateCanonicalVersion(address implementation) public view {
        _validateVersion(implementation);
    }

    function _validateVersion(address implementation) internal view {
        (bool success, bytes memory result) = implementation.staticcall(abi.encodeCall(LendingPoolV1_2.version, ()));
        if (!success) revert VersionReadFailed(implementation);
        bytes memory expected = abi.encode("1.2");
        if (result.length == expected.length && keccak256(result) == keccak256(expected)) return;
        if (!_isCanonicalStringEncoding(result)) revert VersionReadFailed(implementation);
        string memory actual = abi.decode(result, (string));
        revert UnexpectedVersion(actual);
    }

    function _isCanonicalStringEncoding(bytes memory result) internal pure returns (bool) {
        if (result.length < 64) return false;
        uint256 offset;
        uint256 stringLength;
        assembly ("memory-safe") {
            offset := mload(add(result, 0x20))
            stringLength := mload(add(result, 0x40))
        }
        if (offset != 32 || stringLength > result.length - 64) return false;
        uint256 paddedLength = (stringLength + 31) & ~uint256(31);
        if (result.length != 64 + paddedLength) return false;
        for (uint256 i = 64 + stringLength; i < result.length; ++i) {
            if (result[i] != bytes1(0)) return false;
        }
        return true;
    }

    function _readProxyAddress(address proxy, bytes4 selector) internal view returns (address) {
        uint256 value = uint256(_readProxyWord(proxy, selector));
        if (value > type(uint160).max) revert ProxyInterfaceReadFailed(proxy, selector);
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(value));
    }

    function _readProxyUint(address proxy, bytes4 selector) internal view returns (uint256) {
        return uint256(_readProxyWord(proxy, selector));
    }

    function _readProxyUintWithAddress(address proxy, bytes4 selector, address account)
        internal
        view
        returns (uint256 value)
    {
        (bool success, bytes memory result) = proxy.staticcall(abi.encodeWithSelector(selector, account));
        if (!success || result.length != 32) revert ProxyInterfaceReadFailed(proxy, selector);
        value = abi.decode(result, (uint256));
    }

    function _readProxyWord(address proxy, bytes4 selector) internal view returns (bytes32 word) {
        (bool success, bytes memory result) = proxy.staticcall(abi.encodeWithSelector(selector));
        if (!success || result.length != 32) revert ProxyInterfaceReadFailed(proxy, selector);
        word = abi.decode(result, (bytes32));
    }

    function _readBalance(address token, address account) internal view returns (uint256) {
        return _readExternalUint(token, abi.encodeCall(IERC20.balanceOf, (account)));
    }

    function _readExternalUint(address target, bytes memory callData) internal view returns (uint256 value) {
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(callData, 0x20))
        }
        (bool success, bytes memory result) = target.staticcall(callData);
        if (!success || result.length != 32) revert SnapshotReadFailed(target, selector);
        value = abi.decode(result, (uint256));
    }

    function _check(bytes32 field, bytes32 expected, bytes32 actual) internal pure {
        if (expected != actual) revert ProxyStateChanged(field, expected, actual);
    }

    function _addressWord(address value) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    function _nextDeploymentAddress(address sender) internal view returns (address) {
        return vm.computeCreateAddress(sender, vm.getNonce(sender));
    }

    function _broadcastSender() internal returns (address sender) {
        (, sender,) = vm.readCallers();
    }

    function _readUpgradeConfig() internal view returns (UpgradeConfig memory config) {
        config = UpgradeConfig({
            expectedChainId: vm.envUint("EXPECTED_CHAIN_ID"),
            lendingPoolProxy: vm.envAddress("LENDING_POOL_PROXY"),
            expectedCurrentImplementation: vm.envAddress("EXPECTED_CURRENT_IMPLEMENTATION"),
            expectedContractUpgradeAuthority: vm.envAddress("EXPECTED_UPGRADE_AUTHORITY"),
            expectedPendingUpgradeAuthority: vm.envAddress("EXPECTED_PENDING_UPGRADE_AUTHORITY"),
            trackedAccountSetIsComplete: vm.envBool("TRACKED_ACCOUNT_SET_IS_COMPLETE"),
            trackedAccounts: vm.envAddress("TRACKED_ACCOUNTS", ",")
        });
    }

    function _logPreparation(PreparedTransaction memory prepared) internal view {
        console2.log("V1.2 implementation deployed; proxy is NOT upgraded.");
        console2.log("Fresh preflight is required immediately before Safe execution.");
        console2.log("Chain ID:", block.chainid);
        console2.log("Operator-supplied contract upgrade authority:", prepared.expectedContractUpgradeAuthority);
        console2.log("Safe owner set, threshold, nonce, EIP-712 hash, signatures, and approvals are not authenticated.");
        console2.log("Those Safe-specific checks require a separate public preflight.");
        console2.log("Prepared transaction intended for execution by that authority; target:", prepared.target);
        console2.log("Prepared transaction value:", prepared.value);
        console2.log("Prepared transaction calldata:");
        console2.logBytes(prepared.data);
        console2.log("Authenticated directly constructed candidate extcodehash:");
        console2.logBytes32(prepared.newImplementationCodeHash);
        console2.log("Tracked-account count:", prepared.preUpgradeState.trackedAccounts.length);
        if (!prepared.preUpgradeState.trackedAccountSetIsComplete) {
            console2.log("WARNING: supplied tracked-account set is not claimed complete.");
        }
        console2.log("Operator must derive the canonical account set from deployment/interaction evidence.");
        console2.log("The tool does not claim enumeration of arbitrary mapping storage.");
        console2.log("Authenticated bytecode plus separately reviewed migration logic completes the guarantee.");
        _logIncidentalBalances(
            "Old implementation incidental balances", prepared.preUpgradeState.oldImplementationBalances
        );
        _logIncidentalBalances(
            "New implementation incidental balances", prepared.preUpgradeState.newImplementationBalances
        );
        console2.log("Pre-upgrade snapshot ABI encoding:");
        console2.logBytes(abi.encode(prepared.preUpgradeState));
        console2.log("Pre-upgrade state hash (evidence and verifier input):");
        console2.logBytes32(prepared.preUpgradeStateHash);
        console2.log("Tooling/audit payload fingerprint (NOT an official Safe transaction hash):");
        console2.logBytes32(prepared.payloadFingerprint);
        console2.log("Canonical tracked-account commitment:");
        console2.logBytes32(prepared.trackedAccountCommitment);
        console2.log("PREPARATION ATTESTATION DIGEST (not a signature, Safe hash, or on-chain attestation):");
        console2.logBytes32(prepared.preparationAttestationDigest);
        console2.log("Preserve this digest independently from the evidence bundle as the verifier trust root.");
    }

    function _logIncidentalBalances(
        string memory label,
        LendingPoolV1_2UpgradeStateFingerprint.ImplementationBalanceSnapshot memory balances
    ) internal pure {
        console2.log(label);
        console2.log("  implementation:", balances.implementation);
        console2.log("  collateral token:", balances.collateralAssetBalance);
        console2.log("  debt token:", balances.debtAssetBalance);
        console2.log("  vault shares:", balances.vaultShareBalance);
        if (balances.collateralAssetBalance != 0 || balances.debtAssetBalance != 0 || balances.vaultShareBalance != 0) {
            console2.log("  WARNING: nonzero permissionlessly transferable incidental balance recorded.");
        }
    }
}
