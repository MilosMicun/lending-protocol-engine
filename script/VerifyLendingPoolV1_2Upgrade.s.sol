// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LendingPool} from "../src/core/lending/LendingPool.sol";
import {LendingPoolV1_2} from "../src/core/lending/LendingPoolV1_2.sol";
import {
    ILendingPoolV1_2SnapshotView,
    LendingPoolV1_2PreparationAttestation,
    LendingPoolV1_2UpgradeStateFingerprint,
    UpgradeLendingPoolV1_2
} from "./UpgradeLendingPoolV1_2.s.sol";

interface ILendingPoolV1_2VerificationView is ILendingPoolV1_2SnapshotView {
    function version() external pure returns (string memory);
    function currentBorrowIndex() external view returns (uint256);
    function currentBorrowRate() external view returns (uint256);
}

/// @notice Read-only verifier for a completed atomic V1/V1.1 to V1.2 upgrade.
/// @dev This verifies state, not transaction receipts or logs. It makes no claim that a public-chain upgrade occurred.
///      The trusted code hash must come from the preparation script's direct typed construction; a caller-supplied
///      arbitrary address/hash pair alone is not reviewed-bytecode provenance. Mapping continuity covers only the
///      canonical operator-supplied list derived from authenticated deployment/interaction evidence; it does not
///      enumerate arbitrary storage. Exact authenticated bytecode plus separately reviewed migration logic provides
///      the remaining implementation guarantee. Authentic provenance additionally requires the operator to preserve
///      the preparation attestation digest independently from the caller-supplied evidence bundle.
///      If an operator replaces both that bundle and trust root, this local verifier cannot distinguish the result
///      from an authentic workflow without an external signature, immutable registry, verified receipt, or authority.
contract VerifyLendingPoolV1_2Upgrade is Script {
    struct VerificationConfig {
        uint256 expectedChainId;
        address lendingPoolProxy;
        address expectedOldImplementation;
        address expectedNewImplementation;
        bytes32 expectedNewImplementationCodeHash;
        address expectedContractUpgradeAuthority;
        address expectedPendingUpgradeAuthority;
        bool trackedAccountSetIsComplete;
        address[] trackedAccounts;
        uint256 expectedActivationTimestamp;
        bytes32 expectedPreUpgradeStateHash;
        bytes32 expectedTrackedAccountCommitment;
        address preparedTarget;
        uint256 preparedValue;
        bytes preparedData;
        bytes32 expectedPreparedPayloadFingerprint;
        bytes32 trustedPreparationAttestationDigest;
    }

    struct ImplementationIncidentalBalanceDelta {
        LendingPoolV1_2UpgradeStateFingerprint.ImplementationBalanceSnapshot preparationTime;
        LendingPoolV1_2UpgradeStateFingerprint.ImplementationBalanceSnapshot observedPostUpgrade;
        bool collateralAssetChanged;
        bool debtAssetChanged;
        bool vaultShareChanged;
    }

    struct IncidentalBalanceReport {
        ImplementationIncidentalBalanceDelta oldImplementation;
        ImplementationIncidentalBalanceDelta newImplementation;
        bool anyBalanceChanged;
    }

    error UnexpectedChainId(uint256 expected, uint256 actual);
    error InvalidAddress(bytes32 field, address actual);
    error AddressHasNoCode(bytes32 field, address actual);
    error ExpectedAddressesNotDistinct(address proxy, address oldImplementation, address newImplementation);
    error PreUpgradeStateHashMismatch(bytes32 expected, bytes32 actual);
    error PreUpgradeIdentityMismatch(bytes32 field, bytes32 expected, bytes32 actual);
    error UnexpectedCurrentImplementation(bytes32 expected, bytes32 actual);
    error UnexpectedNewImplementationCodeHash(bytes32 expected, bytes32 actual);
    error OldImplementationStillActive(bytes32 oldImplementation, bytes32 actual);
    error ProxiableUUIDReadFailed(address implementation);
    error UnexpectedProxiableUUID(address implementation, bytes32 actualUuid);
    error VersionReadFailed(address proxy);
    error UnexpectedVersion(string actualVersion);
    error UnexpectedInitializedVersion(uint64 expected, uint64 actual);
    error InitializableStillInitializing();
    error UnexpectedActiveUpgradeAuthority(address expected, address actual);
    error UnexpectedPendingUpgradeAuthority(address expected, address actual);
    error SnapshotReadFailed(address target, bytes4 selector);
    error PostUpgradeValueChanged(bytes32 field, bytes32 expected, bytes32 actual);
    error InvalidActivationTimestamp(uint256 previousTimestamp, uint256 activationTimestamp, uint256 nowTimestamp);
    error IncorrectSettledBorrowIndex(uint256 expected, uint256 actual);
    error IncorrectActivationTimestamp(uint256 expected, uint256 actual);
    error CurrentBorrowRateMismatch(uint256 expected, uint256 actual);
    error CurrentBorrowIndexMismatch(uint256 expected, uint256 actual);
    error RayAccrualIntervalTooLong(uint256 elapsed, uint256 maximum);
    error InvalidTrackedAccount(uint256 index, address account);
    error TrackedAccountsNotStrictlySorted(uint256 index, address previous, address account);
    error TrackedAccountTotalsMismatch(bytes32 field, uint256 expected, uint256 actual);
    error PreparationAttestationDigestMismatch(bytes32 trusted, bytes32 recomputed);
    error TrackedAccountCommitmentMismatch(bytes32 expected, bytes32 actual);
    error PreparedTargetMismatch(address expected, address actual);
    error PreparedValueNotZero(uint256 actual);
    error PreparedCalldataMismatch();
    error PreparedPayloadFingerprintMismatch(bytes32 expected, bytes32 actual);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD_TO_RAY = 1e9;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant MAX_RAY_ACCRUAL_ELAPSED = 100 * SECONDS_PER_YEAR;

    bytes32 public constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 public constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    function run()
        external
        view
        returns (
            bytes32 verifiedPreUpgradeStateHash,
            uint256 verifiedCurrentBorrowIndex,
            IncidentalBalanceReport memory incidentalBalanceReport
        )
    {
        VerificationConfig memory config = _readVerificationConfig();
        LendingPoolV1_2UpgradeStateFingerprint.State memory preUpgradeState =
            abi.decode(vm.envBytes("PRE_UPGRADE_STATE_ABI"), (LendingPoolV1_2UpgradeStateFingerprint.State));
        (verifiedPreUpgradeStateHash, verifiedCurrentBorrowIndex, incidentalBalanceReport) =
            verifyPostUpgrade(config, preUpgradeState);

        console2.log("V1.2 post-upgrade state verified (no receipt/log verification was performed).");
        console2.log("Trusted preparation attestation digest supplied through an independent channel:");
        console2.logBytes32(config.trustedPreparationAttestationDigest);
        console2.log("This digest is not a signature, Safe transaction hash, or on-chain attestation.");
        console2.log("Authenticity depends on keeping the trusted digest independent from the evidence bundle.");
        console2.log("Proxy:", config.lendingPoolProxy);
        console2.log("V1.2 implementation:", config.expectedNewImplementation);
        console2.log("Authenticated candidate extcodehash:");
        console2.logBytes32(config.expectedNewImplementationCodeHash);
        console2.log("Operator-supplied contract upgrade authority:", config.expectedContractUpgradeAuthority);
        console2.log("Safe owner set, threshold, nonce, EIP-712 hash, signatures, and approvals were not verified.");
        console2.log("Those Safe-specific checks require a separate public preflight.");
        console2.log("Tracked-account count:", config.trackedAccounts.length);
        if (!config.trackedAccountSetIsComplete) {
            console2.log("WARNING: continuity is proven only for the supplied canonical tracked-account set.");
        }
        console2.log("The tool does not claim enumeration of arbitrary mapping storage.");
        console2.log("Authenticated bytecode plus separately reviewed migration logic completes the guarantee.");
        console2.log("Activation timestamp:", config.expectedActivationTimestamp);
        console2.log("Verified pre-upgrade state hash:");
        console2.logBytes32(verifiedPreUpgradeStateHash);
        console2.log("Current independently verified V1.2 borrow index:", verifiedCurrentBorrowIndex);
        _logIncidentalBalanceReport(incidentalBalanceReport);
    }

    function verifyPostUpgrade(
        VerificationConfig memory config,
        LendingPoolV1_2UpgradeStateFingerprint.State memory preUpgradeState
    )
        public
        view
        returns (
            bytes32 verifiedPreUpgradeStateHash,
            uint256 verifiedCurrentBorrowIndex,
            IncidentalBalanceReport memory incidentalBalanceReport
        )
    {
        if (config.expectedChainId != block.chainid) {
            revert UnexpectedChainId(config.expectedChainId, block.chainid);
        }
        _validateContract("proxy", config.lendingPoolProxy);
        _validateContract("oldImplementation", config.expectedOldImplementation);
        _validateContract("newImplementation", config.expectedNewImplementation);
        _validateContract("contractUpgradeAuthority", config.expectedContractUpgradeAuthority);
        _validateTrackedAccounts(config.trackedAccounts);
        if (
            config.lendingPoolProxy == config.expectedOldImplementation
                || config.lendingPoolProxy == config.expectedNewImplementation
                || config.expectedOldImplementation == config.expectedNewImplementation
        ) {
            revert ExpectedAddressesNotDistinct(
                config.lendingPoolProxy, config.expectedOldImplementation, config.expectedNewImplementation
            );
        }

        verifiedPreUpgradeStateHash = LendingPoolV1_2UpgradeStateFingerprint.calculate(preUpgradeState);
        if (verifiedPreUpgradeStateHash != config.expectedPreUpgradeStateHash) {
            revert PreUpgradeStateHashMismatch(config.expectedPreUpgradeStateHash, verifiedPreUpgradeStateHash);
        }
        _validatePreUpgradeIdentity(config, preUpgradeState);
        _validateTrustedPreparationAttestation(config);
        _validatePreparedEvidence(config);

        bytes32 implementationWord = vm.load(config.lendingPoolProxy, ERC1967_IMPLEMENTATION_SLOT);
        bytes32 expectedNewWord = _addressWord(config.expectedNewImplementation);
        if (implementationWord != expectedNewWord) {
            revert UnexpectedCurrentImplementation(expectedNewWord, implementationWord);
        }
        bytes32 oldWord = _addressWord(config.expectedOldImplementation);
        if (implementationWord == oldWord) revert OldImplementationStillActive(oldWord, implementationWord);
        bytes32 actualCodeHash = config.expectedNewImplementation.codehash;
        if (actualCodeHash != config.expectedNewImplementationCodeHash) {
            revert UnexpectedNewImplementationCodeHash(config.expectedNewImplementationCodeHash, actualCodeHash);
        }
        _validateProxiableUuid(config.expectedNewImplementation);
        _validateVersion(config.lendingPoolProxy);
        _validateInitializableState(config.lendingPoolProxy);

        UpgradeLendingPoolV1_2.ProxySnapshot memory postUpgradeState =
            _snapshot(config.lendingPoolProxy, config.trackedAccounts);
        if (postUpgradeState.activeUpgradeAuthority != config.expectedContractUpgradeAuthority) {
            revert UnexpectedActiveUpgradeAuthority(
                config.expectedContractUpgradeAuthority, postUpgradeState.activeUpgradeAuthority
            );
        }
        if (postUpgradeState.pendingUpgradeAuthority != config.expectedPendingUpgradeAuthority) {
            revert UnexpectedPendingUpgradeAuthority(
                config.expectedPendingUpgradeAuthority, postUpgradeState.pendingUpgradeAuthority
            );
        }

        _verifyContinuity(preUpgradeState, postUpgradeState);
        if (config.trackedAccountSetIsComplete) {
            _validateTrackedTotals(postUpgradeState.accounting, postUpgradeState.trackedAccounts);
        }
        _verifyMigrationBoundary(
            config, preUpgradeState.accounting, preUpgradeState.configuration, postUpgradeState.accounting
        );
        verifiedCurrentBorrowIndex = _verifyCurrentV12Accounting(config.lendingPoolProxy, postUpgradeState);
        incidentalBalanceReport = _reportImplementationBalances(preUpgradeState);
    }

    /// @notice Exact historical V1/V1.1 settlement model, including checked arithmetic and original operation order.
    /// @dev Deliberately does not call BorrowIndexMath or Math.mulDiv for the legacy interval.
    function expectedLegacySettledBorrowIndex(
        LendingPoolV1_2UpgradeStateFingerprint.AccountingSnapshot memory accounting,
        LendingPoolV1_2UpgradeStateFingerprint.ConfigurationSnapshot memory configuration,
        uint256 activationTimestamp
    ) public pure returns (uint256) {
        uint256 elapsed = activationTimestamp - accounting.lastBorrowIndexUpdate;
        if (elapsed == 0) return accounting.borrowIndex;
        if (accounting.totalScaledDebt == 0) return accounting.borrowIndex;

        uint256 utilization;
        if (accounting.totalLiquidity != 0) {
            uint256 storedDebt = accounting.totalScaledDebt * accounting.borrowIndex / WAD;
            utilization = storedDebt >= accounting.totalLiquidity ? WAD : storedDebt * WAD / accounting.totalLiquidity;
        }
        uint256 legacyRate = configuration.baseBorrowRate + utilization * configuration.borrowRateSlope / WAD;
        uint256 interestFactor = legacyRate * elapsed / SECONDS_PER_YEAR;
        uint256 secondOrderTerm = interestFactor * interestFactor / (2 * WAD);
        return accounting.borrowIndex * (WAD + interestFactor + secondOrderTerm) / WAD;
    }

    function expectedRayAccruedBorrowIndex(uint256 indexWad, uint256 rateWad, uint256 elapsed)
        public
        pure
        returns (uint256)
    {
        if (elapsed == 0 || rateWad == 0) return indexWad;
        if (elapsed > MAX_RAY_ACCRUAL_ELAPSED) {
            revert RayAccrualIntervalTooLong(elapsed, MAX_RAY_ACCRUAL_ELAPSED);
        }
        uint256 baseRay = RAY + Math.mulDiv(rateWad, WAD_TO_RAY, SECONDS_PER_YEAR, Math.Rounding.Floor);
        uint256 growthRay = _powRayFloor(baseRay, elapsed);
        return Math.mulDiv(indexWad, growthRay, RAY, Math.Rounding.Floor);
    }

    function _verifyMigrationBoundary(
        VerificationConfig memory config,
        LendingPoolV1_2UpgradeStateFingerprint.AccountingSnapshot memory beforeAccounting,
        LendingPoolV1_2UpgradeStateFingerprint.ConfigurationSnapshot memory beforeConfiguration,
        LendingPoolV1_2UpgradeStateFingerprint.AccountingSnapshot memory afterAccounting
    ) internal view {
        if (
            config.expectedActivationTimestamp < beforeAccounting.lastBorrowIndexUpdate
                || config.expectedActivationTimestamp > block.timestamp
        ) {
            revert InvalidActivationTimestamp(
                beforeAccounting.lastBorrowIndexUpdate, config.expectedActivationTimestamp, block.timestamp
            );
        }
        uint256 expectedSettled =
            expectedLegacySettledBorrowIndex(beforeAccounting, beforeConfiguration, config.expectedActivationTimestamp);
        if (afterAccounting.borrowIndex != expectedSettled) {
            revert IncorrectSettledBorrowIndex(expectedSettled, afterAccounting.borrowIndex);
        }
        if (afterAccounting.lastBorrowIndexUpdate != config.expectedActivationTimestamp) {
            revert IncorrectActivationTimestamp(
                config.expectedActivationTimestamp, afterAccounting.lastBorrowIndexUpdate
            );
        }
    }

    function _verifyCurrentV12Accounting(address proxy, UpgradeLendingPoolV1_2.ProxySnapshot memory postUpgradeState)
        internal
        view
        returns (uint256 currentIndex)
    {
        LendingPoolV1_2UpgradeStateFingerprint.AccountingSnapshot memory accounting = postUpgradeState.accounting;
        LendingPoolV1_2UpgradeStateFingerprint.ConfigurationSnapshot memory configuration =
        postUpgradeState.configuration;
        uint256 utilization;
        if (accounting.totalLiquidity != 0) {
            uint256 storedDebt = Math.mulDiv(accounting.totalScaledDebt, accounting.borrowIndex, WAD);
            utilization =
                storedDebt >= accounting.totalLiquidity ? WAD : Math.mulDiv(storedDebt, WAD, accounting.totalLiquidity);
        }
        uint256 expectedRate = configuration.baseBorrowRate
            + Math.mulDiv(utilization, configuration.borrowRateSlope, WAD, Math.Rounding.Floor);
        uint256 actualRate = _readUint(proxy, ILendingPoolV1_2VerificationView.currentBorrowRate.selector);
        if (actualRate != expectedRate) revert CurrentBorrowRateMismatch(expectedRate, actualRate);

        uint256 expectedIndex = accounting.totalScaledDebt == 0
            ? accounting.borrowIndex
            : expectedRayAccruedBorrowIndex(
                accounting.borrowIndex, expectedRate, block.timestamp - accounting.lastBorrowIndexUpdate
            );
        currentIndex = _readUint(proxy, ILendingPoolV1_2VerificationView.currentBorrowIndex.selector);
        if (currentIndex != expectedIndex) revert CurrentBorrowIndexMismatch(expectedIndex, currentIndex);
    }

    function _verifyContinuity(
        LendingPoolV1_2UpgradeStateFingerprint.State memory beforeState,
        UpgradeLendingPoolV1_2.ProxySnapshot memory afterState
    ) internal pure {
        _check(
            "activeAuthority",
            _addressWord(beforeState.activeUpgradeAuthority),
            _addressWord(afterState.activeUpgradeAuthority)
        );
        _check(
            "pendingAuthority",
            _addressWord(beforeState.pendingUpgradeAuthority),
            _addressWord(afterState.pendingUpgradeAuthority)
        );
        _check(
            "configuration",
            keccak256(abi.encode(beforeState.configuration)),
            keccak256(abi.encode(afterState.configuration))
        );
        _check(
            "totalCollateralShares",
            bytes32(beforeState.accounting.totalCollateralShares),
            bytes32(afterState.accounting.totalCollateralShares)
        );
        _check(
            "totalLiquidity",
            bytes32(beforeState.accounting.totalLiquidity),
            bytes32(afterState.accounting.totalLiquidity)
        );
        _check(
            "totalScaledDebt",
            bytes32(beforeState.accounting.totalScaledDebt),
            bytes32(afterState.accounting.totalScaledDebt)
        );
        _check("custody", keccak256(abi.encode(beforeState.custody)), keccak256(abi.encode(afterState.custody)));
        _check(
            "trackedAccounts",
            keccak256(abi.encode(beforeState.trackedAccounts)),
            keccak256(abi.encode(afterState.trackedAccounts))
        );
        for (uint256 slot; slot < beforeState.protocolSlots.length; ++slot) {
            if (slot == 8 || slot == 9) continue;
            _check(bytes32(slot), beforeState.protocolSlots[slot], afterState.protocolSlots[slot]);
        }
    }

    /// @dev Incidental direct implementation balances are permissionlessly mutable and never gate the core verdict.
    ///      Proxy and vault custody remain authoritative invariants in `_verifyContinuity`.
    function _reportImplementationBalances(LendingPoolV1_2UpgradeStateFingerprint.State memory beforeState)
        internal
        view
        returns (IncidentalBalanceReport memory report)
    {
        report.oldImplementation = _implementationBalanceDelta(
            beforeState.oldImplementationBalances,
            _snapshotImplementationBalances(beforeState.configuration, beforeState.oldImplementation)
        );
        report.newImplementation = _implementationBalanceDelta(
            beforeState.newImplementationBalances,
            _snapshotImplementationBalances(beforeState.configuration, beforeState.newImplementation)
        );
        report.anyBalanceChanged = _hasIncidentalBalanceChange(report.oldImplementation)
            || _hasIncidentalBalanceChange(report.newImplementation);
    }

    function _implementationBalanceDelta(
        LendingPoolV1_2UpgradeStateFingerprint.ImplementationBalanceSnapshot memory preparationTime,
        LendingPoolV1_2UpgradeStateFingerprint.ImplementationBalanceSnapshot memory observedPostUpgrade
    ) internal pure returns (ImplementationIncidentalBalanceDelta memory delta) {
        delta.preparationTime = preparationTime;
        delta.observedPostUpgrade = observedPostUpgrade;
        delta.collateralAssetChanged =
            preparationTime.collateralAssetBalance != observedPostUpgrade.collateralAssetBalance;
        delta.debtAssetChanged = preparationTime.debtAssetBalance != observedPostUpgrade.debtAssetBalance;
        delta.vaultShareChanged = preparationTime.vaultShareBalance != observedPostUpgrade.vaultShareBalance;
    }

    function _hasIncidentalBalanceChange(ImplementationIncidentalBalanceDelta memory delta)
        internal
        pure
        returns (bool)
    {
        return delta.collateralAssetChanged || delta.debtAssetChanged || delta.vaultShareChanged;
    }

    function _validateTrustedPreparationAttestation(VerificationConfig memory config) internal pure {
        bytes32 recomputed = LendingPoolV1_2PreparationAttestation.calculate(
            LendingPoolV1_2PreparationAttestation.Attestation({
                formatVersion: LendingPoolV1_2PreparationAttestation.formatVersion(),
                chainId: config.expectedChainId,
                proxy: config.lendingPoolProxy,
                expectedContractUpgradeAuthority: config.expectedContractUpgradeAuthority,
                expectedPendingUpgradeAuthority: config.expectedPendingUpgradeAuthority,
                oldImplementation: config.expectedOldImplementation,
                newImplementation: config.expectedNewImplementation,
                newImplementationCodeHash: config.expectedNewImplementationCodeHash,
                trackedAccountCommitment: config.expectedTrackedAccountCommitment,
                preUpgradeStateHash: config.expectedPreUpgradeStateHash,
                target: config.preparedTarget,
                value: config.preparedValue,
                data: config.preparedData,
                payloadFingerprint: config.expectedPreparedPayloadFingerprint
            })
        );
        if (recomputed != config.trustedPreparationAttestationDigest) {
            revert PreparationAttestationDigestMismatch(config.trustedPreparationAttestationDigest, recomputed);
        }
    }

    function _validatePreparedEvidence(VerificationConfig memory config) internal pure {
        bytes32 actualTrackedAccountCommitment = keccak256(abi.encode(config.trackedAccounts));
        if (actualTrackedAccountCommitment != config.expectedTrackedAccountCommitment) {
            revert TrackedAccountCommitmentMismatch(
                config.expectedTrackedAccountCommitment, actualTrackedAccountCommitment
            );
        }
        if (config.preparedTarget != config.lendingPoolProxy) {
            revert PreparedTargetMismatch(config.lendingPoolProxy, config.preparedTarget);
        }
        if (config.preparedValue != 0) revert PreparedValueNotZero(config.preparedValue);
        bytes memory migration = abi.encodeCall(LendingPoolV1_2.migrateToV1_2, ());
        bytes memory canonicalData = abi.encodeWithSelector(
            UUPSUpgradeable.upgradeToAndCall.selector, config.expectedNewImplementation, migration
        );
        if (
            config.preparedData.length != canonicalData.length
                || keccak256(config.preparedData) != keccak256(canonicalData)
        ) {
            revert PreparedCalldataMismatch();
        }
        bytes32 actualPayloadFingerprint = LendingPoolV1_2PreparationAttestation.calculatePayloadFingerprint(
            config.expectedChainId,
            config.expectedContractUpgradeAuthority,
            config.preparedTarget,
            config.preparedValue,
            config.preparedData
        );
        if (actualPayloadFingerprint != config.expectedPreparedPayloadFingerprint) {
            revert PreparedPayloadFingerprintMismatch(
                config.expectedPreparedPayloadFingerprint, actualPayloadFingerprint
            );
        }
    }

    function _validatePreUpgradeIdentity(
        VerificationConfig memory config,
        LendingPoolV1_2UpgradeStateFingerprint.State memory state
    ) internal pure {
        _identity("chainId", bytes32(config.expectedChainId), bytes32(state.chainId));
        _identity("proxy", _addressWord(config.lendingPoolProxy), _addressWord(state.proxy));
        _identity(
            "oldImplementation", _addressWord(config.expectedOldImplementation), _addressWord(state.oldImplementation)
        );
        _identity(
            "newImplementation", _addressWord(config.expectedNewImplementation), _addressWord(state.newImplementation)
        );
        _identity(
            "newImplementationCodeHash", config.expectedNewImplementationCodeHash, state.newImplementationCodeHash
        );
        _identity(
            "activeAuthority",
            _addressWord(config.expectedContractUpgradeAuthority),
            _addressWord(state.activeUpgradeAuthority)
        );
        _identity(
            "pendingAuthority",
            _addressWord(config.expectedPendingUpgradeAuthority),
            _addressWord(state.pendingUpgradeAuthority)
        );
        _identity(
            "trackedAccountSetIsComplete",
            bytes32(uint256(config.trackedAccountSetIsComplete ? 1 : 0)),
            bytes32(uint256(state.trackedAccountSetIsComplete ? 1 : 0))
        );
        _identity("trackedAccounts", keccak256(abi.encode(config.trackedAccounts)), _trackedAddressHash(state));
    }

    function _snapshot(address proxy, address[] memory trackedAccounts)
        internal
        view
        returns (UpgradeLendingPoolV1_2.ProxySnapshot memory state)
    {
        state.lendingPoolProxy = proxy;
        state.implementationWord = vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT);
        state.initializableNamespace = vm.load(proxy, INITIALIZABLE_STORAGE);
        state.activeUpgradeAuthority = _readAddress(proxy, LendingPool.upgradeAuthority.selector);
        state.pendingUpgradeAuthority = _readAddress(proxy, LendingPool.pendingUpgradeAuthority.selector);
        for (uint256 slot; slot < state.protocolSlots.length; ++slot) {
            state.protocolSlots[slot] = vm.load(proxy, bytes32(slot));
        }
        state.configuration = _snapshotConfiguration(proxy);
        state.accounting = _snapshotAccounting(proxy);
        state.custody = _snapshotCustody(proxy, state.configuration);
        state.trackedAccounts = _snapshotTrackedAccounts(proxy, trackedAccounts);
    }

    function _snapshotConfiguration(address proxy)
        internal
        view
        returns (LendingPoolV1_2UpgradeStateFingerprint.ConfigurationSnapshot memory config)
    {
        config.priceFeed = _readAddress(proxy, ILendingPoolV1_2SnapshotView.priceFeed.selector);
        config.vault = _readAddress(proxy, ILendingPoolV1_2SnapshotView.vault.selector);
        config.debtAsset = _readAddress(proxy, ILendingPoolV1_2SnapshotView.debtAsset.selector);
        config.collateralAsset = _readAddress(proxy, ILendingPoolV1_2SnapshotView.collateralAsset.selector);
        config.maxPriceStaleness = _readUint(proxy, ILendingPoolV1_2SnapshotView.maxPriceStaleness.selector);
        config.ltvBps = _readUint(proxy, ILendingPoolV1_2SnapshotView.ltvBps.selector);
        config.liquidationThresholdBps = _readUint(proxy, ILendingPoolV1_2SnapshotView.liquidationThresholdBps.selector);
        config.liquidationBonusBps = _readUint(proxy, ILendingPoolV1_2SnapshotView.liquidationBonusBps.selector);
        config.baseBorrowRate = _readUint(proxy, ILendingPoolV1_2SnapshotView.baseBorrowRate.selector);
        config.borrowRateSlope = _readUint(proxy, ILendingPoolV1_2SnapshotView.borrowRateSlope.selector);
    }

    function _snapshotAccounting(address proxy)
        internal
        view
        returns (LendingPoolV1_2UpgradeStateFingerprint.AccountingSnapshot memory accounting)
    {
        accounting.borrowIndex = _readUint(proxy, ILendingPoolV1_2SnapshotView.borrowIndex.selector);
        accounting.lastBorrowIndexUpdate = _readUint(proxy, ILendingPoolV1_2SnapshotView.lastBorrowIndexUpdate.selector);
        accounting.totalCollateralShares = _readUint(proxy, ILendingPoolV1_2SnapshotView.totalCollateralShares.selector);
        accounting.totalLiquidity = _readUint(proxy, ILendingPoolV1_2SnapshotView.totalLiquidity.selector);
        accounting.totalScaledDebt = _readUint(proxy, ILendingPoolV1_2SnapshotView.totalScaledDebt.selector);
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
                scaledDebt: _readUintWithAddress(proxy, ILendingPoolV1_2SnapshotView.scaledDebtOf.selector, account),
                collateralShares: _readUintWithAddress(
                    proxy, ILendingPoolV1_2SnapshotView.collateralSharesOf.selector, account
                ),
                liquidityBalance: _readUintWithAddress(
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

    function _trackedAddressHash(LendingPoolV1_2UpgradeStateFingerprint.State memory state)
        internal
        pure
        returns (bytes32)
    {
        address[] memory accounts = new address[](state.trackedAccounts.length);
        for (uint256 i; i < accounts.length; ++i) {
            accounts[i] = state.trackedAccounts[i].account;
        }
        return keccak256(abi.encode(accounts));
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

    function _snapshotImplementationBalances(
        LendingPoolV1_2UpgradeStateFingerprint.ConfigurationSnapshot memory config,
        address implementation
    ) internal view returns (LendingPoolV1_2UpgradeStateFingerprint.ImplementationBalanceSnapshot memory balances) {
        balances.implementation = implementation;
        balances.collateralAssetBalance = _readBalance(config.collateralAsset, implementation);
        balances.debtAssetBalance = _readBalance(config.debtAsset, implementation);
        balances.vaultShareBalance = _readBalance(config.vault, implementation);
    }

    function _validateInitializableState(address proxy) internal view {
        uint256 word = uint256(vm.load(proxy, INITIALIZABLE_STORAGE));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 initialized = uint64(word & type(uint64).max);
        if (initialized != 2) revert UnexpectedInitializedVersion(2, initialized);
        if (((word >> 64) & 0xff) != 0) revert InitializableStillInitializing();
    }

    function validateCanonicalVersion(address proxy) public view {
        _validateVersion(proxy);
    }

    function _validateVersion(address proxy) internal view {
        (bool success, bytes memory result) =
            proxy.staticcall(abi.encodeCall(ILendingPoolV1_2VerificationView.version, ()));
        if (!success) revert VersionReadFailed(proxy);
        bytes memory expected = abi.encode("1.2");
        if (result.length == expected.length && keccak256(result) == keccak256(expected)) return;
        if (!_isCanonicalStringEncoding(result)) revert VersionReadFailed(proxy);
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

    function _validateProxiableUuid(address implementation) internal view {
        (bool success, bytes memory result) =
            implementation.staticcall(abi.encodeCall(IERC1822Proxiable.proxiableUUID, ()));
        if (!success || result.length != 32) revert ProxiableUUIDReadFailed(implementation);
        bytes32 uuid = abi.decode(result, (bytes32));
        if (uuid != ERC1967_IMPLEMENTATION_SLOT) revert UnexpectedProxiableUUID(implementation, uuid);
    }

    function _validateContract(bytes32 field, address account) internal view {
        if (account == address(0)) revert InvalidAddress(field, account);
        if (account.code.length == 0) revert AddressHasNoCode(field, account);
    }

    function _readAddress(address target, bytes4 selector) internal view returns (address) {
        uint256 value = _readUint(target, selector);
        if (value > type(uint160).max) revert SnapshotReadFailed(target, selector);
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(value));
    }

    function _readUint(address target, bytes4 selector) internal view returns (uint256 value) {
        (bool success, bytes memory result) = target.staticcall(abi.encodeWithSelector(selector));
        if (!success || result.length != 32) revert SnapshotReadFailed(target, selector);
        value = abi.decode(result, (uint256));
    }

    function _readUintWithAddress(address target, bytes4 selector, address account)
        internal
        view
        returns (uint256 value)
    {
        (bool success, bytes memory result) = target.staticcall(abi.encodeWithSelector(selector, account));
        if (!success || result.length != 32) revert SnapshotReadFailed(target, selector);
        value = abi.decode(result, (uint256));
    }

    function _readBalance(address token, address account) internal view returns (uint256) {
        return _readExternalUint(token, abi.encodeCall(IERC20.balanceOf, (account)));
    }

    function _readExternalUint(address target, bytes memory data) internal view returns (uint256 value) {
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(data, 0x20))
        }
        (bool success, bytes memory result) = target.staticcall(data);
        if (!success || result.length != 32) revert SnapshotReadFailed(target, selector);
        value = abi.decode(result, (uint256));
    }

    function _powRayFloor(uint256 baseRay, uint256 exponent) internal pure returns (uint256 resultRay) {
        resultRay = RAY;
        while (exponent != 0) {
            if (exponent & 1 != 0) resultRay = Math.mulDiv(resultRay, baseRay, RAY, Math.Rounding.Floor);
            exponent >>= 1;
            if (exponent != 0) baseRay = Math.mulDiv(baseRay, baseRay, RAY, Math.Rounding.Floor);
        }
    }

    function _check(bytes32 field, bytes32 expected, bytes32 actual) internal pure {
        if (expected != actual) revert PostUpgradeValueChanged(field, expected, actual);
    }

    function _identity(bytes32 field, bytes32 expected, bytes32 actual) internal pure {
        if (expected != actual) revert PreUpgradeIdentityMismatch(field, expected, actual);
    }

    function _addressWord(address value) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    function _logIncidentalBalanceReport(IncidentalBalanceReport memory report) internal pure {
        console2.log("Implementation incidental direct balances are informational, not protocol custody.");
        _logImplementationIncidentalDelta("Old implementation", report.oldImplementation);
        _logImplementationIncidentalDelta("New implementation", report.newImplementation);
        if (report.anyBalanceChanged) {
            console2.log("WARNING: incidental direct implementation balance delta(s) observed; core verdict unchanged.");
        }
    }

    function _logImplementationIncidentalDelta(string memory label, ImplementationIncidentalBalanceDelta memory delta)
        internal
        pure
    {
        console2.log(label);
        console2.log("  implementation:", delta.preparationTime.implementation);
        console2.log("  preparation collateral token:", delta.preparationTime.collateralAssetBalance);
        console2.log("  observed collateral token:", delta.observedPostUpgrade.collateralAssetBalance);
        console2.log("  preparation debt token:", delta.preparationTime.debtAssetBalance);
        console2.log("  observed debt token:", delta.observedPostUpgrade.debtAssetBalance);
        console2.log("  preparation vault shares:", delta.preparationTime.vaultShareBalance);
        console2.log("  observed vault shares:", delta.observedPostUpgrade.vaultShareBalance);
    }

    function _readVerificationConfig() internal view returns (VerificationConfig memory config) {
        config = VerificationConfig({
            expectedChainId: vm.envUint("EXPECTED_CHAIN_ID"),
            lendingPoolProxy: vm.envAddress("LENDING_POOL_PROXY"),
            expectedOldImplementation: vm.envAddress("EXPECTED_OLD_IMPLEMENTATION"),
            expectedNewImplementation: vm.envAddress("EXPECTED_NEW_IMPLEMENTATION"),
            expectedNewImplementationCodeHash: vm.envBytes32("EXPECTED_NEW_IMPLEMENTATION_CODE_HASH"),
            expectedContractUpgradeAuthority: vm.envAddress("EXPECTED_UPGRADE_AUTHORITY"),
            expectedPendingUpgradeAuthority: vm.envAddress("EXPECTED_PENDING_UPGRADE_AUTHORITY"),
            trackedAccountSetIsComplete: vm.envBool("TRACKED_ACCOUNT_SET_IS_COMPLETE"),
            trackedAccounts: vm.envAddress("TRACKED_ACCOUNTS", ","),
            expectedActivationTimestamp: vm.envUint("EXPECTED_V1_2_ACTIVATION_TIMESTAMP"),
            expectedPreUpgradeStateHash: vm.envBytes32("EXPECTED_PRE_UPGRADE_STATE_HASH"),
            expectedTrackedAccountCommitment: vm.envBytes32("EXPECTED_TRACKED_ACCOUNT_COMMITMENT"),
            preparedTarget: vm.envAddress("PREPARED_TARGET"),
            preparedValue: vm.envUint("PREPARED_VALUE"),
            preparedData: vm.envBytes("PREPARED_CALLDATA"),
            expectedPreparedPayloadFingerprint: vm.envBytes32("EXPECTED_PREPARED_PAYLOAD_FINGERPRINT"),
            trustedPreparationAttestationDigest: vm.envBytes32("TRUSTED_PREPARATION_ATTESTATION_DIGEST")
        });
    }
}
