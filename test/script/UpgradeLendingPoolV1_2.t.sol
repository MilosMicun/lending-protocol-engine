// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {
    LendingPoolV1_2PreparationAttestation,
    LendingPoolV1_2UpgradeStateFingerprint,
    UpgradeLendingPoolV1_2
} from "../../script/UpgradeLendingPoolV1_2.s.sol";
import {VerifyLendingPoolV1_2Upgrade} from "../../script/VerifyLendingPoolV1_2Upgrade.s.sol";
import {LendingPool} from "../../src/core/lending/LendingPool.sol";
import {LendingPoolV1_1} from "../../src/core/lending/LendingPoolV1_1.sol";
import {LendingPoolV1_2} from "../../src/core/lending/LendingPoolV1_2.sol";
import {CollateralVault} from "../../src/core/vault/CollateralVault.sol";
import {BorrowIndexMath} from "../../src/lib/BorrowIndexMath.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {WrongUUIDImplementation} from "../mocks/WrongUUIDImplementation.sol";

contract V1_2SafeLikeAuthority {
    function forward(address target, uint256 value, bytes calldata data) external payable returns (bytes memory) {
        require(msg.value == value, "value mismatch");
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        return result;
    }
}

contract V1_2SixDecimalERC20 is MockERC20 {
    constructor() MockERC20("Six Decimal Debt", "SIX") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract V1_2MaliciousLookalike is Initializable, UUPSUpgradeable {
    constructor() {
        _disableInitializers();
    }

    function version() external pure returns (string memory) {
        return "1.2";
    }

    // The look-alike deliberately mimics the canonical migration selector.
    // forge-lint: disable-next-line(mixed-case-function)
    function migrateToV1_2() external reinitializer(2) {}

    function _authorizeUpgrade(address) internal pure override {}
}

contract V1_2RawVersionResponder {
    bytes internal response;

    constructor(bytes memory response_) {
        response = response_;
    }

    fallback() external {
        bytes memory result = response;
        assembly ("memory-safe") {
            return(add(result, 0x20), mload(result))
        }
    }
}

contract UpgradeLendingPoolV1_2Test is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 internal constant UPGRADE_AUTHORITY_STORAGE =
        0x8000ce11f38414f298b74975bfaea500fcdbebb431834e96f66ac2883c9bb800;

    UpgradeLendingPoolV1_2 internal upgrader;
    VerifyLendingPoolV1_2Upgrade internal verifier;
    V1_2SafeLikeAuthority internal safe;
    MockERC20 internal collateralToken;
    MockERC20 internal debtToken;
    MockV3Aggregator internal priceFeed;
    CollateralVault internal vault;
    LendingPool internal oldImplementation;
    LendingPool internal pool;

    address internal borrower = makeAddr("borrower");
    address internal provider = makeAddr("provider");
    address internal pendingAuthority = makeAddr("pendingAuthority");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        upgrader = new UpgradeLendingPoolV1_2();
        verifier = new VerifyLendingPoolV1_2Upgrade();
        safe = new V1_2SafeLikeAuthority();
        collateralToken = new MockERC20("Collateral", "COL");
        debtToken = new MockERC20("Debt", "DEBT");
        priceFeed = new MockV3Aggregator(8, 1e8, block.timestamp);
        vault = new CollateralVault("Vault Share", "VSH", collateralToken);
        _redeploy(new LendingPool());
    }

    function test_PreparesFromInitializedV1WithExactAtomicSafeTransaction() public {
        UpgradeLendingPoolV1_2.PreparedTransaction memory prepared = upgrader.prepare(_config());

        assertEq(prepared.target, address(pool));
        assertEq(prepared.value, 0);
        assertEq(prepared.expectedContractUpgradeAuthority, address(safe));
        assertEq(prepared.expectedPendingUpgradeAuthority, address(0));
        assertEq(
            prepared.data,
            abi.encodeWithSelector(
                UUPSUpgradeable.upgradeToAndCall.selector,
                prepared.newImplementation,
                abi.encodeCall(LendingPoolV1_2.migrateToV1_2, ())
            )
        );
        (, bytes memory inner) = _decodePayload(prepared.data);
        assertEq(inner.length, 4);
        // The preceding length assertion proves the cast retains the complete inner call.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(bytes4(inner), LendingPoolV1_2.migrateToV1_2.selector);
        assertEq(_implementation(), address(oldImplementation));
    }

    function test_PreparesFromInitializedV1_1() public {
        _redeploy(new LendingPoolV1_1());
        UpgradeLendingPoolV1_2.PreparedTransaction memory prepared = upgrader.prepare(_config());
        assertEq(LendingPoolV1_2(prepared.newImplementation).version(), "1.2");
        assertEq(_implementation(), address(oldImplementation));
    }

    function test_PreparationDoesNotMutateRepresentativeProxyState() public {
        _seedRepresentativeState();
        _safeForward(abi.encodeCall(LendingPool.proposeUpgradeAuthority, (pendingAuthority)));
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        config.expectedPendingUpgradeAuthority = pendingAuthority;
        bytes32 beforeHash = keccak256(abi.encode(upgrader.snapshot(address(pool), config.trackedAccounts)));

        UpgradeLendingPoolV1_2.PreparedTransaction memory prepared = upgrader.prepare(config);

        assertEq(keccak256(abi.encode(upgrader.snapshot(address(pool), config.trackedAccounts))), beforeHash);
        assertEq(_implementation(), address(oldImplementation));
        assertEq(prepared.preUpgradeState.pendingUpgradeAuthority, pendingAuthority);
    }

    function test_RunBroadcastBoundaryDeploysImplementationOnly() public {
        _setRunEnvironment();
        address implementationBefore = _implementation();
        uint64 broadcasterNonce = vm.getNonce(DEFAULT_SENDER);

        UpgradeLendingPoolV1_2.PreparedTransaction memory prepared = upgrader.run();

        assertEq(prepared.newImplementation, vm.computeCreateAddress(DEFAULT_SENDER, broadcasterNonce));
        assertEq(vm.getNonce(DEFAULT_SENDER), broadcasterNonce + 1);
        assertEq(_implementation(), implementationBefore);
        assertEq(uint256(vm.load(address(pool), INITIALIZABLE_STORAGE)) & type(uint64).max, 1);
    }

    function test_FingerprintsAreDeterministicAndDomainSeparated() public {
        UpgradeLendingPoolV1_2.PreparedTransaction memory prepared = upgrader.prepare(_config());
        assertEq(prepared.preUpgradeStateHash, upgrader.calculateStateFingerprint(prepared.preUpgradeState));
        assertEq(
            prepared.payloadFingerprint,
            upgrader.calculatePayloadFingerprint(block.chainid, address(safe), address(pool), 0, prepared.data)
        );
        assertNotEq(prepared.preUpgradeStateHash, prepared.payloadFingerprint);
        assertNotEq(prepared.preparationAttestationDigest, prepared.preUpgradeStateHash);
        assertNotEq(prepared.preparationAttestationDigest, prepared.payloadFingerprint);
        assertEq(prepared.trackedAccountCommitment, keccak256(abi.encode(_trackedAccounts())));
        assertEq(
            prepared.preparationAttestationDigest, _attestationDigest(_verificationConfig(prepared, block.timestamp))
        );
        assertEq(prepared.newImplementationCodeHash, prepared.newImplementation.codehash);
        assertEq(prepared.preUpgradeState.newImplementationCodeHash, prepared.newImplementationCodeHash);
    }

    function test_AuthenticPreparationAttestationDigestSucceeds() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        (bytes32 verifiedHash,, VerifyLendingPoolV1_2Upgrade.IncidentalBalanceReport memory report) =
            verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
        assertEq(verifiedHash, prepared.preUpgradeStateHash);
        assertFalse(report.anyBalanceChanged);
    }

    function test_VerifierRejectsOneBitPreparationAttestationDigestMutation() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        VerifyLendingPoolV1_2Upgrade.VerificationConfig memory config = _verificationConfig(prepared, activation);
        config.trustedPreparationAttestationDigest = bytes32(uint256(config.trustedPreparationAttestationDigest) ^ 1);
        _expectAttestationMismatch(config, prepared.preUpgradeState);
    }

    function test_VerifierRejectsDigestFromAnotherAuthenticPreparationAndCandidate() public {
        UpgradeLendingPoolV1_2.PreparedTransaction memory prepared = upgrader.prepare(_config());
        UpgradeLendingPoolV1_2.PreparedTransaction memory otherPrepared = upgrader.prepare(_config());
        assertNotEq(prepared.newImplementation, otherPrepared.newImplementation);
        assertNotEq(prepared.preparationAttestationDigest, otherPrepared.preparationAttestationDigest);
        uint256 activation = block.timestamp;
        safe.forward(prepared.target, prepared.value, prepared.data);

        VerifyLendingPoolV1_2Upgrade.VerificationConfig memory config = _verificationConfig(prepared, activation);
        config.trustedPreparationAttestationDigest = otherPrepared.preparationAttestationDigest;
        _expectAttestationMismatch(config, prepared.preUpgradeState);
    }

    function test_VerifierRejectsDigestBoundToAnotherProxyOrChain() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        VerifyLendingPoolV1_2Upgrade.VerificationConfig memory config = _verificationConfig(prepared, activation);
        VerifyLendingPoolV1_2Upgrade.VerificationConfig memory altered = _verificationConfig(prepared, activation);
        altered.lendingPoolProxy = makeAddr("anotherProxy");
        config.trustedPreparationAttestationDigest = _attestationDigest(altered);
        _expectAttestationMismatch(config, prepared.preUpgradeState);

        altered = _verificationConfig(prepared, activation);
        altered.expectedChainId++;
        config = _verificationConfig(prepared, activation);
        config.trustedPreparationAttestationDigest = _attestationDigest(altered);
        _expectAttestationMismatch(config, prepared.preUpgradeState);
    }

    function test_VerifierRejectsChangedTrackedAccountCommitmentAtTrustRoot() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        VerifyLendingPoolV1_2Upgrade.VerificationConfig memory config = _verificationConfig(prepared, activation);
        config.expectedTrackedAccountCommitment = bytes32(uint256(config.expectedTrackedAccountCommitment) ^ 1);
        _expectAttestationMismatch(config, prepared.preUpgradeState);
    }

    function test_VerifierRejectsChangedPayloadFingerprintAtTrustRoot() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        VerifyLendingPoolV1_2Upgrade.VerificationConfig memory config = _verificationConfig(prepared, activation);
        config.expectedPreparedPayloadFingerprint = bytes32(uint256(config.expectedPreparedPayloadFingerprint) ^ 1);
        _expectAttestationMismatch(config, prepared.preUpgradeState);
    }

    function test_TrustedDigestRejectsInternallyConsistentLookalikeReplacementEvidence() public {
        UpgradeLendingPoolV1_2.PreparedTransaction memory authentic = upgrader.prepare(_config());
        bytes32 independentlyPreservedDigest = authentic.preparationAttestationDigest;
        V1_2MaliciousLookalike lookalike = new V1_2MaliciousLookalike();
        bytes memory replacementData = abi.encodeWithSelector(
            UUPSUpgradeable.upgradeToAndCall.selector,
            address(lookalike),
            abi.encodeCall(V1_2MaliciousLookalike.migrateToV1_2, ())
        );
        safe.forward(address(pool), 0, replacementData);

        LendingPoolV1_2UpgradeStateFingerprint.State memory replacementState = authentic.preUpgradeState;
        replacementState.newImplementation = address(lookalike);
        replacementState.newImplementationCodeHash = address(lookalike).codehash;
        replacementState.newImplementationBalances =
            upgrader.snapshotImplementationBalances(replacementState.configuration, address(lookalike));

        VerifyLendingPoolV1_2Upgrade.VerificationConfig memory replacement =
            _verificationConfig(authentic, block.timestamp);
        replacement.expectedNewImplementation = address(lookalike);
        replacement.expectedNewImplementationCodeHash = address(lookalike).codehash;
        replacement.expectedPreUpgradeStateHash = upgrader.calculateStateFingerprint(replacementState);
        replacement.preparedData = replacementData;
        replacement.expectedPreparedPayloadFingerprint =
            upgrader.calculatePayloadFingerprint(block.chainid, address(safe), address(pool), 0, replacementData);
        replacement.trustedPreparationAttestationDigest = independentlyPreservedDigest;

        assertEq(_implementation(), address(lookalike));
        assertEq(lookalike.proxiableUUID(), ERC1967_IMPLEMENTATION_SLOT);
        assertEq(LendingPoolV1_2(address(pool)).version(), "1.2");
        assertEq(uint256(vm.load(address(pool), INITIALIZABLE_STORAGE)) & type(uint64).max, 2);
        assertEq(replacement.expectedPreUpgradeStateHash, upgrader.calculateStateFingerprint(replacementState));
        assertEq(replacement.expectedTrackedAccountCommitment, keccak256(abi.encode(replacement.trackedAccounts)));
        assertEq(
            replacement.expectedPreparedPayloadFingerprint,
            upgrader.calculatePayloadFingerprint(
                replacement.expectedChainId,
                replacement.expectedContractUpgradeAuthority,
                replacement.preparedTarget,
                replacement.preparedValue,
                replacement.preparedData
            )
        );
        assertNotEq(_attestationDigest(replacement), independentlyPreservedDigest);
        _expectAttestationMismatch(replacement, replacementState);
    }

    function test_NewImplementationInitializationAndMigrationAreLocked() public {
        UpgradeLendingPoolV1_2.PreparedTransaction memory prepared = upgrader.prepare(_config());
        assertEq(
            uint256(vm.load(prepared.newImplementation, INITIALIZABLE_STORAGE)) & type(uint64).max, type(uint64).max
        );
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        LendingPoolV1_2(prepared.newImplementation).migrateToV1_2();
    }

    function test_NonzeroImplementationIncidentalBalancesAreVisibleFingerprintBoundAndPreserved() public {
        address predicted = vm.computeCreateAddress(address(upgrader), vm.getNonce(address(upgrader)));
        _fundIncidentalBalances(address(oldImplementation), predicted);
        uint256 proxyDebtBefore = debtToken.balanceOf(address(pool));
        uint256 vaultAssetsBefore = vault.totalAssets();

        UpgradeLendingPoolV1_2.PreparedTransaction memory prepared = upgrader.prepare(_config());

        assertEq(prepared.newImplementation, predicted);
        assertEq(prepared.preUpgradeState.oldImplementationBalances.collateralAssetBalance, 3);
        assertEq(prepared.preUpgradeState.oldImplementationBalances.debtAssetBalance, 5);
        assertEq(prepared.preUpgradeState.oldImplementationBalances.vaultShareBalance, 7);
        assertEq(prepared.preUpgradeState.newImplementationBalances.collateralAssetBalance, 11);
        assertEq(prepared.preUpgradeState.newImplementationBalances.debtAssetBalance, 13);
        assertEq(prepared.preUpgradeState.newImplementationBalances.vaultShareBalance, 17);
        assertEq(prepared.preUpgradeStateHash, upgrader.calculateStateFingerprint(prepared.preUpgradeState));
        assertEq(debtToken.balanceOf(address(pool)), proxyDebtBefore);
        assertEq(vault.totalAssets(), vaultAssetsBefore);

        uint256 activation = block.timestamp;
        safe.forward(prepared.target, prepared.value, prepared.data);
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function test_OldImplementationIncidentalBalanceDeltasAreInformationalForAllAssets() public {
        address dustSender = _seedIncidentalTransferSource(2, 3, 5);
        UpgradeLendingPoolV1_2.PreparedTransaction memory prepared = upgrader.prepare(_config());
        _transferIncidentalBalances(dustSender, address(oldImplementation), 2, 3, 5);
        safe.forward(prepared.target, prepared.value, prepared.data);
        (bytes32 verifiedHash,, VerifyLendingPoolV1_2Upgrade.IncidentalBalanceReport memory report) =
            verifier.verifyPostUpgrade(_verificationConfig(prepared, block.timestamp), prepared.preUpgradeState);

        assertEq(verifiedHash, prepared.preUpgradeStateHash);
        assertTrue(report.anyBalanceChanged);
        _assertIncidentalDelta(report.oldImplementation, address(oldImplementation), 2, 3, 5);
        assertFalse(report.newImplementation.collateralAssetChanged);
        assertFalse(report.newImplementation.debtAssetChanged);
        assertFalse(report.newImplementation.vaultShareChanged);
    }

    function test_V1ToV1_2SafeLikeAtomicFlowAndVerifier() public {
        _assertSuccessfulFlow();
    }

    function test_V1_1ToV1_2SafeLikeAtomicFlowAndVerifier() public {
        _redeploy(new LendingPoolV1_1());
        _assertSuccessfulFlow();
    }

    function test_EnvironmentBackedPostUpgradeVerifierRunIsReadOnlyAndAcceptsValidFlow() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        _setVerifierEnvironment(prepared, activation);
        bytes32 stateBefore = keccak256(abi.encode(upgrader.snapshot(address(pool), _trackedAccounts())));

        (bytes32 verifiedHash, uint256 verifiedIndex,) = verifier.run();

        assertEq(verifiedHash, prepared.preUpgradeStateHash);
        assertEq(verifiedIndex, LendingPoolV1_2(address(pool)).currentBorrowIndex());
        assertEq(keccak256(abi.encode(upgrader.snapshot(address(pool), _trackedAccounts()))), stateBefore);
    }

    function test_LegacyBoundaryAndPostActivationRayAccrualAreExact() public {
        _seedRepresentativeState();
        uint256 priorTimestamp = pool.lastBorrowIndexUpdate();
        vm.warp(priorTimestamp + 73 days);
        UpgradeLendingPoolV1_2.PreparedTransaction memory prepared = upgrader.prepare(_config());
        uint256 expectedLegacy = verifier.expectedLegacySettledBorrowIndex(
            prepared.preUpgradeState.accounting, prepared.preUpgradeState.configuration, block.timestamp
        );
        uint256 activationTimestamp = block.timestamp;

        safe.forward(prepared.target, prepared.value, prepared.data);
        assertEq(pool.borrowIndex(), expectedLegacy);
        assertEq(pool.lastBorrowIndexUpdate(), activationTimestamp);

        uint256 postActivationRate = LendingPoolV1_2(address(pool)).currentBorrowRate();
        vm.warp(activationTimestamp + 31 days);
        uint256 expectedRay = BorrowIndexMath.accrueIndex(expectedLegacy, postActivationRate, 31 days);
        (bytes32 verifiedHash, uint256 verifiedCurrentIndex,) =
            verifier.verifyPostUpgrade(_verificationConfig(prepared, activationTimestamp), prepared.preUpgradeState);
        assertEq(verifiedHash, prepared.preUpgradeStateHash);
        assertEq(verifiedCurrentIndex, expectedRay);
        assertEq(LendingPoolV1_2(address(pool)).currentBorrowIndex(), expectedRay);
        assertEq(pool.lastBorrowIndexUpdate(), activationTimestamp);
    }

    function test_PreflightRejectsWrongChainId() public {
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        config.expectedChainId++;
        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeLendingPoolV1_2.UnexpectedChainId.selector, config.expectedChainId, block.chainid
            )
        );
        upgrader.prepare(config);
    }

    function test_PreflightRejectsZeroProxy() public {
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        config.lendingPoolProxy = address(0);
        vm.expectRevert(abi.encodeWithSelector(UpgradeLendingPoolV1_2.InvalidLendingPoolProxy.selector, address(0)));
        upgrader.prepare(config);
    }

    function test_PreflightRejectsProxyWithoutCode() public {
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        config.lendingPoolProxy = stranger;
        vm.expectRevert(abi.encodeWithSelector(UpgradeLendingPoolV1_2.LendingPoolProxyHasNoCode.selector, stranger));
        upgrader.prepare(config);
    }

    function test_PreflightRejectsWrongExpectedCurrentImplementation() public {
        LendingPool other = new LendingPool();
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        config.expectedCurrentImplementation = address(other);
        vm.expectPartialRevert(UpgradeLendingPoolV1_2.UnexpectedCurrentImplementation.selector);
        upgrader.prepare(config);
    }

    function test_PreflightRejectsZeroExpectedCurrentImplementation() public {
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        config.expectedCurrentImplementation = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(UpgradeLendingPoolV1_2.InvalidExpectedCurrentImplementation.selector, address(0))
        );
        upgrader.prepare(config);
    }

    function test_PreflightRejectsZeroExpectedUpgradeAuthority() public {
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        config.expectedContractUpgradeAuthority = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(UpgradeLendingPoolV1_2.InvalidExpectedContractUpgradeAuthority.selector, address(0))
        );
        upgrader.prepare(config);
    }

    function test_PreflightRejectsCodeLessConfiguredAuthority() public {
        _redeployWithAuthority(stranger);
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        config.expectedContractUpgradeAuthority = stranger;
        vm.expectRevert(
            abi.encodeWithSelector(UpgradeLendingPoolV1_2.ExpectedContractUpgradeAuthorityHasNoCode.selector, stranger)
        );
        upgrader.prepare(config);
    }

    function test_PreflightRejectsIncorrectCurrentImplementationUUPSUUID() public {
        WrongUUIDImplementation wrong = new WrongUUIDImplementation();
        vm.store(address(pool), ERC1967_IMPLEMENTATION_SLOT, _addressWord(address(wrong)));
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        config.expectedCurrentImplementation = address(wrong);
        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeLendingPoolV1_2.UnexpectedProxiableUUID.selector, address(wrong), bytes32(uint256(1))
            )
        );
        upgrader.prepare(config);
    }

    function test_PreflightRejectsOldImplementationWithoutCode() public {
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        config.expectedCurrentImplementation = stranger;
        vm.expectRevert(
            abi.encodeWithSelector(UpgradeLendingPoolV1_2.ExpectedCurrentImplementationHasNoCode.selector, stranger)
        );
        upgrader.prepare(config);
    }

    function test_PreflightRejectsUnexpectedActiveAuthority() public {
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        V1_2SafeLikeAuthority otherAuthority = new V1_2SafeLikeAuthority();
        config.expectedContractUpgradeAuthority = address(otherAuthority);
        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeLendingPoolV1_2.UnexpectedActiveUpgradeAuthority.selector, address(otherAuthority), address(safe)
            )
        );
        upgrader.prepare(config);
    }

    function test_PreflightRejectsUnexpectedPendingAuthority() public {
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        config.expectedPendingUpgradeAuthority = pendingAuthority;
        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeLendingPoolV1_2.UnexpectedPendingUpgradeAuthority.selector, pendingAuthority, address(0)
            )
        );
        upgrader.prepare(config);
    }

    function test_ArbitraryExistingCandidateCannotEnterOperationalPreparation() public {
        V1_2MaliciousLookalike lookalike = new V1_2MaliciousLookalike();
        bytes4 removedSelector =
            bytes4(keccak256("prepareExisting((uint256,address,address,address,address,bool,address[]),address)"));
        (bool success,) = address(upgrader).call(abi.encodeWithSelector(removedSelector, _config(), address(lookalike)));
        assertFalse(success);
    }

    function test_AuthenticCandidateEvidenceRejectsLookalikeRuntimeSubstitution() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        V1_2MaliciousLookalike lookalike = new V1_2MaliciousLookalike();
        assertEq(lookalike.proxiableUUID(), ERC1967_IMPLEMENTATION_SLOT);
        assertEq(lookalike.version(), "1.2");
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        lookalike.migrateToV1_2();

        vm.etch(prepared.newImplementation, address(lookalike).code);
        bytes32 substitutedCodeHash = prepared.newImplementation.codehash;
        assertNotEq(substitutedCodeHash, prepared.newImplementationCodeHash);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyLendingPoolV1_2Upgrade.UnexpectedNewImplementationCodeHash.selector,
                prepared.newImplementationCodeHash,
                substitutedCodeHash
            )
        );
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function test_PreflightRejectsZeroTrackedAccount() public {
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        config.trackedAccounts[0] = address(0);
        vm.expectRevert(abi.encodeWithSelector(UpgradeLendingPoolV1_2.InvalidTrackedAccount.selector, 0, address(0)));
        upgrader.prepare(config);
    }

    function test_PreflightRejectsDuplicateTrackedAccount() public {
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        config.trackedAccounts[1] = config.trackedAccounts[0];
        vm.expectPartialRevert(UpgradeLendingPoolV1_2.TrackedAccountsNotStrictlySorted.selector);
        upgrader.prepare(config);
    }

    function test_PreflightRejectsUnsortedTrackedAccounts() public {
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        (config.trackedAccounts[0], config.trackedAccounts[1]) = (config.trackedAccounts[1], config.trackedAccounts[0]);
        vm.expectPartialRevert(UpgradeLendingPoolV1_2.TrackedAccountsNotStrictlySorted.selector);
        upgrader.prepare(config);
    }

    function test_CompleteTrackedSetMustSumToAllAggregates() public {
        _seedRepresentativeState();
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        config.trackedAccounts = new address[](1);
        config.trackedAccounts[0] = borrower;
        vm.expectPartialRevert(UpgradeLendingPoolV1_2.TrackedAccountTotalsMismatch.selector);
        upgrader.prepare(config);
    }

    function test_IncompleteCanonicalTrackedSetIsFingerprintBoundWithoutEnumerationClaim() public {
        _seedRepresentativeState();
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        config.trackedAccountSetIsComplete = false;
        config.trackedAccounts = new address[](1);
        config.trackedAccounts[0] = borrower;
        UpgradeLendingPoolV1_2.PreparedTransaction memory prepared = upgrader.prepare(config);

        assertFalse(prepared.preUpgradeState.trackedAccountSetIsComplete);
        assertEq(prepared.preUpgradeState.trackedAccounts.length, 1);
        assertEq(prepared.preUpgradeState.trackedAccounts[0].account, borrower);
        assertEq(prepared.preUpgradeState.trackedAccounts[0].scaledDebt, pool.scaledDebtOf(borrower));
    }

    function test_CanonicalVersionRejectsMalformedOffset() public {
        bytes memory response = abi.encode("1.2");
        assembly ("memory-safe") {
            mstore(add(response, 0x20), 0x40)
        }
        _assertMalformedVersion(response);
    }

    function test_CanonicalVersionRejectsTruncatedReturnData() public {
        _assertMalformedVersion(hex"20");
    }

    function test_CanonicalVersionRejectsIncorrectLength() public {
        bytes memory response = abi.encode("1.2");
        assembly ("memory-safe") {
            mstore(add(response, 0x40), 0x21)
        }
        _assertMalformedVersion(response);
    }

    function test_CanonicalVersionRejectsNonzeroPadding() public {
        bytes memory response = abi.encode("1.2");
        response[67] = bytes1(0x01);
        _assertMalformedVersion(response);
    }

    function test_CanonicalVersionRejectsValidPrefixWithTrailingData() public {
        _assertMalformedVersion(bytes.concat(abi.encode("1.2"), bytes32(0)));
    }

    function test_CanonicalVersionRejectsAnotherCanonicalVersionSpecifically() public {
        V1_2RawVersionResponder responder = new V1_2RawVersionResponder(abi.encode("1.1"));
        vm.expectRevert(abi.encodeWithSelector(UpgradeLendingPoolV1_2.UnexpectedVersion.selector, "1.1"));
        upgrader.validateCanonicalVersion(address(responder));
        vm.expectRevert(abi.encodeWithSelector(VerifyLendingPoolV1_2Upgrade.UnexpectedVersion.selector, "1.1"));
        verifier.validateCanonicalVersion(address(responder));
    }

    function test_PayloadValidatorRejectsEmptyInnerCalldata() public {
        LendingPoolV1_2 candidate = new LendingPoolV1_2();
        bytes memory data =
            abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, address(candidate), bytes(""));
        vm.expectRevert(UpgradeLendingPoolV1_2.EmptyMigrationCalldata.selector);
        _validatePayload(address(pool), address(safe), address(candidate), address(pool), 0, data);
    }

    function test_PayloadValidatorRejectsTruncatedOuterCalldataWithoutDecodePanic() public {
        LendingPoolV1_2 candidate = new LendingPoolV1_2();
        bytes memory data = _prefix(upgrader.encodeUpgradeCall(address(candidate)), 80);
        vm.expectRevert(abi.encodeWithSelector(UpgradeLendingPoolV1_2.TruncatedOuterCalldata.selector, 100, 80));
        _validatePayload(address(pool), address(safe), address(candidate), address(pool), 0, data);
    }

    function test_PayloadValidatorRejectsNoncanonicalDynamicOffset() public {
        LendingPoolV1_2 candidate = new LendingPoolV1_2();
        bytes memory data = upgrader.encodeUpgradeCall(address(candidate));
        assembly ("memory-safe") {
            mstore(add(data, 0x44), 0x60)
        }
        vm.expectRevert(abi.encodeWithSelector(UpgradeLendingPoolV1_2.NonCanonicalDynamicOffset.selector, 64, 96));
        _validatePayload(address(pool), address(safe), address(candidate), address(pool), 0, data);
    }

    function test_PayloadValidatorRejectsOverlappingDynamicOffset() public {
        LendingPoolV1_2 candidate = new LendingPoolV1_2();
        bytes memory data = upgrader.encodeUpgradeCall(address(candidate));
        assembly ("memory-safe") {
            mstore(add(data, 0x44), 0x20)
        }
        vm.expectRevert(abi.encodeWithSelector(UpgradeLendingPoolV1_2.NonCanonicalDynamicOffset.selector, 64, 32));
        _validatePayload(address(pool), address(safe), address(candidate), address(pool), 0, data);
    }

    function test_PayloadValidatorRejectsIncorrectInnerSelector() public {
        LendingPoolV1_2 candidate = new LendingPoolV1_2();
        bytes memory incorrectInner = abi.encodePacked(bytes4(0xdeadbeef));
        bytes memory data =
            abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, address(candidate), incorrectInner);
        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeLendingPoolV1_2.IncorrectInnerSelector.selector,
                LendingPoolV1_2.migrateToV1_2.selector,
                bytes4(0xdeadbeef)
            )
        );
        _validatePayload(address(pool), address(safe), address(candidate), address(pool), 0, data);
    }

    function test_PayloadValidatorRejectsInnerCalldataWithTrailingByte() public {
        LendingPoolV1_2 candidate = new LendingPoolV1_2();
        bytes memory inner = bytes.concat(abi.encodeCall(LendingPoolV1_2.migrateToV1_2, ()), bytes1(0x00));
        bytes memory data = abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, address(candidate), inner);
        vm.expectRevert(abi.encodeWithSelector(UpgradeLendingPoolV1_2.IncorrectInnerCalldataLength.selector, 4, 5));
        _validatePayload(address(pool), address(safe), address(candidate), address(pool), 0, data);
    }

    function test_PayloadValidatorRejectsIncorrectOuterSelector() public {
        LendingPoolV1_2 candidate = new LendingPoolV1_2();
        bytes memory data = upgrader.encodeUpgradeCall(address(candidate));
        data[0] = bytes1(uint8(data[0]) ^ 1);
        vm.expectPartialRevert(UpgradeLendingPoolV1_2.IncorrectOuterSelector.selector);
        _validatePayload(address(pool), address(safe), address(candidate), address(pool), 0, data);
    }

    function test_PayloadValidatorRejectsIncorrectTarget() public {
        LendingPoolV1_2 candidate = new LendingPoolV1_2();
        bytes memory data = upgrader.encodeUpgradeCall(address(candidate));
        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeLendingPoolV1_2.IncorrectPreparedTarget.selector, address(pool), address(safe)
            )
        );
        _validatePayload(address(pool), address(safe), address(candidate), address(safe), 0, data);
    }

    function test_PayloadValidatorRejectsNonzeroValue() public {
        LendingPoolV1_2 candidate = new LendingPoolV1_2();
        bytes memory data = upgrader.encodeUpgradeCall(address(candidate));
        vm.expectRevert(abi.encodeWithSelector(UpgradeLendingPoolV1_2.NonzeroPreparedValue.selector, 1));
        _validatePayload(address(pool), address(safe), address(candidate), address(pool), 1, data);
    }

    function test_PayloadValidatorRejectsDifferentImplementation() public {
        LendingPoolV1_2 validated = new LendingPoolV1_2();
        LendingPoolV1_2 encoded = new LendingPoolV1_2();
        bytes memory data = upgrader.encodeUpgradeCall(address(encoded));
        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeLendingPoolV1_2.PayloadImplementationMismatch.selector, address(validated), address(encoded)
            )
        );
        _validatePayload(address(pool), address(safe), address(validated), address(pool), 0, data);
    }

    function test_PayloadValidatorRejectsTrailingData() public {
        LendingPoolV1_2 candidate = new LendingPoolV1_2();
        bytes memory data = bytes.concat(upgrader.encodeUpgradeCall(address(candidate)), bytes1(0x00));
        vm.expectRevert(abi.encodeWithSelector(UpgradeLendingPoolV1_2.IncorrectOuterCalldataLength.selector, 132, 133));
        _validatePayload(address(pool), address(safe), address(candidate), address(pool), 0, data);
    }

    function test_PayloadValidatorRejectsNonzeroCanonicalPadding() public {
        LendingPoolV1_2 candidate = new LendingPoolV1_2();
        bytes memory data = upgrader.encodeUpgradeCall(address(candidate));
        data[104] = bytes1(0x01);
        vm.expectRevert(
            abi.encodeWithSelector(UpgradeLendingPoolV1_2.NonzeroCanonicalPadding.selector, 104, bytes1(0x01))
        );
        _validatePayload(address(pool), address(safe), address(candidate), address(pool), 0, data);
    }

    function test_PayloadValidatorRejectsCodeLessExpectedAuthority() public {
        LendingPoolV1_2 candidate = new LendingPoolV1_2();
        bytes memory data = upgrader.encodeUpgradeCall(address(candidate));
        vm.expectRevert(
            abi.encodeWithSelector(UpgradeLendingPoolV1_2.ExpectedContractUpgradeAuthorityHasNoCode.selector, stranger)
        );
        _validatePayload(address(pool), stranger, address(candidate), address(pool), 0, data);
    }

    function test_DirectEOAOwnerCannotExecuteExactPreparedPayload() public {
        UpgradeLendingPoolV1_2.PreparedTransaction memory prepared = upgrader.prepare(_config());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.UnauthorizedUpgradeAuthority.selector, stranger));
        _callAndBubble(prepared.target, prepared.value, prepared.data);
        assertEq(_implementation(), address(oldImplementation));
    }

    function test_UnauthorizedContractCannotExecuteExactPreparedPayload() public {
        UpgradeLendingPoolV1_2.PreparedTransaction memory prepared = upgrader.prepare(_config());
        V1_2SafeLikeAuthority unauthorizedContract = new V1_2SafeLikeAuthority();
        vm.expectRevert(
            abi.encodeWithSelector(LendingPool.UnauthorizedUpgradeAuthority.selector, address(unauthorizedContract))
        );
        unauthorizedContract.forward(prepared.target, prepared.value, prepared.data);
        assertEq(_implementation(), address(oldImplementation));
    }

    function test_ProposedButUnacceptedContractCannotExecuteExactPreparedPayload() public {
        V1_2SafeLikeAuthority proposedAuthority = new V1_2SafeLikeAuthority();
        _safeForward(abi.encodeCall(LendingPool.proposeUpgradeAuthority, (address(proposedAuthority))));
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        config.expectedPendingUpgradeAuthority = address(proposedAuthority);
        UpgradeLendingPoolV1_2.PreparedTransaction memory prepared = upgrader.prepare(config);

        vm.expectRevert(
            abi.encodeWithSelector(LendingPool.UnauthorizedUpgradeAuthority.selector, address(proposedAuthority))
        );
        proposedAuthority.forward(prepared.target, prepared.value, prepared.data);
        assertEq(_implementation(), address(oldImplementation));
    }

    function test_AtomicMigrationFailureRollsBackImplementationAndState() public {
        debtToken = new V1_2SixDecimalERC20();
        vault = new CollateralVault("Vault Share", "VSH", collateralToken);
        _redeploy(new LendingPool());
        _seedRepresentativeState();
        UpgradeLendingPoolV1_2.PreparedTransaction memory prepared = upgrader.prepare(_config());
        bytes32 beforeHash = _rollbackDigest(prepared);

        vm.expectRevert(abi.encodeWithSelector(LendingPoolV1_2.UnsupportedDebtAssetDecimals.selector, uint8(6)));
        safe.forward(prepared.target, prepared.value, prepared.data);

        assertEq(_implementation(), address(oldImplementation));
        assertEq(_rollbackDigest(prepared), beforeHash);
    }

    function test_VerifierRejectsEmptyDataV1_2InstallAsInactive() public {
        UpgradeLendingPoolV1_2.PreparedTransaction memory prepared = upgrader.prepare(_config());
        safe.forward(
            address(pool),
            0,
            abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, prepared.newImplementation, bytes(""))
        );

        vm.expectRevert(
            abi.encodeWithSelector(VerifyLendingPoolV1_2Upgrade.UnexpectedInitializedVersion.selector, 2, 1)
        );
        verifier.verifyPostUpgrade(_verificationConfig(prepared, block.timestamp), prepared.preUpgradeState);
    }

    function test_VerifierRejectsWrongImplementation() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        vm.store(address(pool), ERC1967_IMPLEMENTATION_SLOT, _addressWord(address(oldImplementation)));
        vm.expectPartialRevert(VerifyLendingPoolV1_2Upgrade.UnexpectedCurrentImplementation.selector);
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function test_VerifierRejectsWrongProxyIdentity() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        VerifyLendingPoolV1_2Upgrade.VerificationConfig memory config = _verificationConfig(prepared, activation);
        config.lendingPoolProxy = address(verifier);
        vm.expectPartialRevert(VerifyLendingPoolV1_2Upgrade.PreUpgradeIdentityMismatch.selector);
        verifier.verifyPostUpgrade(config, prepared.preUpgradeState);
    }

    function test_VerifierRejectsWrongOldImplementationIdentity() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        VerifyLendingPoolV1_2Upgrade.VerificationConfig memory config = _verificationConfig(prepared, activation);
        config.expectedOldImplementation = address(new LendingPool());
        vm.expectPartialRevert(VerifyLendingPoolV1_2Upgrade.PreUpgradeIdentityMismatch.selector);
        verifier.verifyPostUpgrade(config, prepared.preUpgradeState);
    }

    function test_VerifierRejectsWrongNewImplementationIdentity() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        LendingPoolV1_2 other = new LendingPoolV1_2();
        VerifyLendingPoolV1_2Upgrade.VerificationConfig memory config = _verificationConfig(prepared, activation);
        config.expectedNewImplementation = address(other);
        config.expectedNewImplementationCodeHash = address(other).codehash;
        vm.expectPartialRevert(VerifyLendingPoolV1_2Upgrade.PreUpgradeIdentityMismatch.selector);
        verifier.verifyPostUpgrade(config, prepared.preUpgradeState);
    }

    function test_VerifierRejectsWrongCandidateCodeHash() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        bytes32 wrongHash = bytes32(uint256(prepared.newImplementationCodeHash) ^ 1);
        prepared.preUpgradeState.newImplementationCodeHash = wrongHash;
        VerifyLendingPoolV1_2Upgrade.VerificationConfig memory config = _verificationConfig(prepared, activation);
        config.expectedNewImplementationCodeHash = wrongHash;
        config.expectedPreUpgradeStateHash = upgrader.calculateStateFingerprint(prepared.preUpgradeState);
        _replaceTrustedAttestationDigest(config);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyLendingPoolV1_2Upgrade.UnexpectedNewImplementationCodeHash.selector,
                wrongHash,
                prepared.newImplementation.codehash
            )
        );
        verifier.verifyPostUpgrade(config, prepared.preUpgradeState);
    }

    function test_VerifierRejectsWrongNewUUPSUUID() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        WrongUUIDImplementation wrong = new WrongUUIDImplementation();
        vm.etch(prepared.newImplementation, address(wrong).code);
        bytes32 wrongCodeHash = prepared.newImplementation.codehash;
        prepared.preUpgradeState.newImplementationCodeHash = wrongCodeHash;
        VerifyLendingPoolV1_2Upgrade.VerificationConfig memory config = _verificationConfig(prepared, activation);
        config.expectedNewImplementationCodeHash = wrongCodeHash;
        config.expectedPreUpgradeStateHash = upgrader.calculateStateFingerprint(prepared.preUpgradeState);
        _replaceTrustedAttestationDigest(config);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyLendingPoolV1_2Upgrade.UnexpectedProxiableUUID.selector,
                prepared.newImplementation,
                bytes32(uint256(1))
            )
        );
        verifier.verifyPostUpgrade(config, prepared.preUpgradeState);
    }

    function test_PostVerifierRejectsMalformedVersionReturnDataWithSpecificError() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        vm.mockCall(address(pool), abi.encodeWithSignature("version()"), hex"20");
        vm.expectRevert(abi.encodeWithSelector(VerifyLendingPoolV1_2Upgrade.VersionReadFailed.selector, address(pool)));
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function test_PostVerifierRejectsWrongCanonicalVersion() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        vm.mockCall(address(pool), abi.encodeWithSignature("version()"), abi.encode("1.1"));
        vm.expectRevert(abi.encodeWithSelector(VerifyLendingPoolV1_2Upgrade.UnexpectedVersion.selector, "1.1"));
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function test_VerifierRejectsActivationTimestampEarlierThanPreUpgradeTimestamp() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared,) = _upgradeValid();
        uint256 invalidActivation = prepared.preUpgradeState.accounting.lastBorrowIndexUpdate - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyLendingPoolV1_2Upgrade.InvalidActivationTimestamp.selector,
                prepared.preUpgradeState.accounting.lastBorrowIndexUpdate,
                invalidActivation,
                block.timestamp
            )
        );
        verifier.verifyPostUpgrade(_verificationConfig(prepared, invalidActivation), prepared.preUpgradeState);
    }

    function test_VerifierRejectsActivationTimestampLaterThanVerificationBlock() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared,) = _upgradeValid();
        uint256 invalidActivation = block.timestamp + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyLendingPoolV1_2Upgrade.InvalidActivationTimestamp.selector,
                prepared.preUpgradeState.accounting.lastBorrowIndexUpdate,
                invalidActivation,
                block.timestamp
            )
        );
        verifier.verifyPostUpgrade(_verificationConfig(prepared, invalidActivation), prepared.preUpgradeState);
    }

    function test_VerifierRejectsInitializedVersionOtherThanTwo() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        vm.store(address(pool), INITIALIZABLE_STORAGE, bytes32(uint256(3)));
        vm.expectRevert(
            abi.encodeWithSelector(VerifyLendingPoolV1_2Upgrade.UnexpectedInitializedVersion.selector, 2, 3)
        );
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function test_VerifierRejectsInitializableStillInitializing() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        vm.store(address(pool), INITIALIZABLE_STORAGE, bytes32(uint256(2) | (uint256(1) << 64)));
        vm.expectRevert(VerifyLendingPoolV1_2Upgrade.InitializableStillInitializing.selector);
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function test_VerifierRejectsWrongChainId() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        VerifyLendingPoolV1_2Upgrade.VerificationConfig memory config = _verificationConfig(prepared, activation);
        config.expectedChainId++;
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyLendingPoolV1_2Upgrade.UnexpectedChainId.selector, config.expectedChainId, block.chainid
            )
        );
        verifier.verifyPostUpgrade(config, prepared.preUpgradeState);
    }

    function test_VerifierRejectsChangedAuthority() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        vm.store(address(pool), UPGRADE_AUTHORITY_STORAGE, _addressWord(stranger));
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyLendingPoolV1_2Upgrade.UnexpectedActiveUpgradeAuthority.selector, address(safe), stranger
            )
        );
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function test_VerifierRejectsChangedPendingAuthority() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        vm.store(address(pool), bytes32(uint256(UPGRADE_AUTHORITY_STORAGE) + 1), _addressWord(pendingAuthority));
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyLendingPoolV1_2Upgrade.UnexpectedPendingUpgradeAuthority.selector, address(0), pendingAuthority
            )
        );
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function test_VerifierRejectsChangedConfiguration() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        vm.store(address(pool), bytes32(uint256(0)), bytes32(pool.ltvBps() + 1));
        vm.expectPartialRevert(VerifyLendingPoolV1_2Upgrade.PostUpgradeValueChanged.selector);
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function test_VerifierRejectsChangedAccountingTotals() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        vm.store(address(pool), bytes32(uint256(11)), bytes32(pool.totalLiquidity() + 1));
        vm.expectPartialRevert(VerifyLendingPoolV1_2Upgrade.PostUpgradeValueChanged.selector);
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function test_VerifierRejectsChangedProxyDebtBalance() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        debtToken.mint(address(pool), 1);
        vm.expectPartialRevert(VerifyLendingPoolV1_2Upgrade.PostUpgradeValueChanged.selector);
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function test_VerifierRejectsChangedProxyCollateralBalance() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        collateralToken.mint(address(pool), 1);
        _expectPostValueChange(prepared, activation);
    }

    function test_VerifierRejectsChangedProxyVaultShareBalance() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        deal(address(vault), address(pool), vault.balanceOf(address(pool)) + 1, false);
        _expectPostValueChange(prepared, activation);
    }

    function test_VerifierRejectsChangedVaultAssetsAndCollateralBalance() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        collateralToken.mint(address(vault), 1);
        _expectPostValueChange(prepared, activation);
    }

    function test_VerifierRejectsChangedVaultTotalSupply() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        deal(address(vault), borrower, vault.balanceOf(borrower) + 1, true);
        _expectPostValueChange(prepared, activation);
    }

    function test_NewImplementationIncidentalBalanceDeltasAreInformationalForAllAssets() public {
        address dustSender = _seedIncidentalTransferSource(7, 11, 13);
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        _transferIncidentalBalances(dustSender, prepared.newImplementation, 7, 11, 13);
        (bytes32 verifiedHash,, VerifyLendingPoolV1_2Upgrade.IncidentalBalanceReport memory report) =
            verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);

        assertEq(verifiedHash, prepared.preUpgradeStateHash);
        assertTrue(report.anyBalanceChanged);
        _assertIncidentalDelta(report.newImplementation, prepared.newImplementation, 7, 11, 13);
        assertFalse(report.oldImplementation.collateralAssetChanged);
        assertFalse(report.oldImplementation.debtAssetChanged);
        assertFalse(report.oldImplementation.vaultShareChanged);
    }

    function test_VerifierRejectsChangedOtherwiseFrozenProtocolSlot() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        vm.store(address(pool), bytes32(uint256(17)), bytes32(uint256(1)));
        vm.expectPartialRevert(VerifyLendingPoolV1_2Upgrade.PostUpgradeValueChanged.selector);
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function test_VerifierRejectsChangedTrackedScaledDebtLeafWithAggregatePreserved() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        _incrementMappingLeaf(borrower, 15);
        _expectPostValueChange(prepared, activation);
    }

    function test_VerifierRejectsChangedTrackedCollateralSharesLeafWithAggregatePreserved() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        _incrementMappingLeaf(borrower, 16);
        _expectPostValueChange(prepared, activation);
    }

    function test_VerifierRejectsChangedTrackedLiquidityBalanceLeafWithAggregatePreserved() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        _incrementMappingLeaf(provider, 17);
        _expectPostValueChange(prepared, activation);
    }

    function test_VerifierRejectsIncorrectSettledIndex() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        vm.store(address(pool), bytes32(uint256(8)), bytes32(pool.borrowIndex() + 1));
        vm.expectPartialRevert(VerifyLendingPoolV1_2Upgrade.IncorrectSettledBorrowIndex.selector);
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function test_VerifierRejectsIncorrectActivationTimestamp() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        vm.store(address(pool), bytes32(uint256(9)), bytes32(activation + 1));
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyLendingPoolV1_2Upgrade.IncorrectActivationTimestamp.selector, activation, activation + 1
            )
        );
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function test_VerifierRejectsMismatchedCurrentPostActivationRate() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        uint256 actual = LendingPoolV1_2(address(pool)).currentBorrowRate();
        vm.mockCall(address(pool), abi.encodeWithSignature("currentBorrowRate()"), abi.encode(actual + 1));
        vm.expectRevert(
            abi.encodeWithSelector(VerifyLendingPoolV1_2Upgrade.CurrentBorrowRateMismatch.selector, actual, actual + 1)
        );
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function test_VerifierRejectsMismatchedCurrentPostActivationIndex() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        uint256 actual = LendingPoolV1_2(address(pool)).currentBorrowIndex();
        vm.mockCall(address(pool), abi.encodeWithSignature("currentBorrowIndex()"), abi.encode(actual + 1));
        vm.expectRevert(
            abi.encodeWithSelector(VerifyLendingPoolV1_2Upgrade.CurrentBorrowIndexMismatch.selector, actual, actual + 1)
        );
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function test_VerifierRejectsStaleOrMismatchedPreUpgradeSnapshot() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        prepared.preUpgradeState.accounting.totalLiquidity++;
        bytes32 actual = upgrader.calculateStateFingerprint(prepared.preUpgradeState);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyLendingPoolV1_2Upgrade.PreUpgradeStateHashMismatch.selector, prepared.preUpgradeStateHash, actual
            )
        );
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function test_VerifierRejectsMismatchedExpectedFingerprint() public {
        (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation) = _upgradeValid();
        VerifyLendingPoolV1_2Upgrade.VerificationConfig memory config = _verificationConfig(prepared, activation);
        config.expectedPreUpgradeStateHash = bytes32(uint256(prepared.preUpgradeStateHash) ^ 1);
        vm.expectPartialRevert(VerifyLendingPoolV1_2Upgrade.PreUpgradeStateHashMismatch.selector);
        verifier.verifyPostUpgrade(config, prepared.preUpgradeState);
    }

    function _assertSuccessfulFlow() internal {
        _seedRepresentativeState();
        _safeForward(abi.encodeCall(LendingPool.proposeUpgradeAuthority, (pendingAuthority)));
        UpgradeLendingPoolV1_2.UpgradeConfig memory config = _config();
        config.expectedPendingUpgradeAuthority = pendingAuthority;
        vm.warp(block.timestamp + 45 days);
        UpgradeLendingPoolV1_2.PreparedTransaction memory prepared = upgrader.prepare(config);
        uint256 activationTimestamp = block.timestamp;

        safe.forward(prepared.target, prepared.value, prepared.data);

        (bytes32 verifiedHash,,) =
            verifier.verifyPostUpgrade(_verificationConfig(prepared, activationTimestamp), prepared.preUpgradeState);
        assertEq(verifiedHash, prepared.preUpgradeStateHash);
        assertEq(_implementation(), prepared.newImplementation);
        assertEq(LendingPoolV1_2(address(pool)).version(), "1.2");
        assertEq(uint256(vm.load(address(pool), INITIALIZABLE_STORAGE)) & type(uint64).max, 2);
        assertEq(pool.upgradeAuthority(), address(safe));
        assertEq(pool.pendingUpgradeAuthority(), pendingAuthority);
        assertEq(pool.totalLiquidity(), prepared.preUpgradeState.accounting.totalLiquidity);
        assertEq(pool.totalScaledDebt(), prepared.preUpgradeState.accounting.totalScaledDebt);
        assertEq(pool.totalCollateralShares(), prepared.preUpgradeState.accounting.totalCollateralShares);
    }

    function _upgradeValid()
        internal
        returns (UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activationTimestamp)
    {
        _seedRepresentativeState();
        vm.warp(block.timestamp + 7 days);
        prepared = upgrader.prepare(_config());
        activationTimestamp = block.timestamp;
        safe.forward(prepared.target, prepared.value, prepared.data);
    }

    function _seedRepresentativeState() internal {
        debtToken.mint(provider, 2_000 ether);
        collateralToken.mint(borrower, 1_000 ether);
        vm.prank(provider);
        debtToken.approve(address(pool), type(uint256).max);
        vm.prank(provider);
        pool.depositLiquidity(2_000 ether);
        vm.prank(borrower);
        collateralToken.approve(address(pool), type(uint256).max);
        vm.prank(borrower);
        pool.depositCollateral(1_000 ether);
        vm.prank(borrower);
        pool.borrow(300 ether);
    }

    function _redeploy(LendingPool implementation) internal {
        oldImplementation = implementation;
        bytes memory initializationData = abi.encodeCall(
            LendingPool.initialize,
            (
                address(priceFeed),
                address(vault),
                address(debtToken),
                500 days,
                7_000,
                8_000,
                500,
                0.05e18,
                0.2e18,
                address(safe)
            )
        );
        pool = LendingPool(address(new ERC1967Proxy(address(implementation), initializationData)));
    }

    function _redeployWithAuthority(address authority) internal {
        oldImplementation = new LendingPool();
        bytes memory initializationData = abi.encodeCall(
            LendingPool.initialize,
            (
                address(priceFeed),
                address(vault),
                address(debtToken),
                500 days,
                7_000,
                8_000,
                500,
                0.05e18,
                0.2e18,
                authority
            )
        );
        pool = LendingPool(address(new ERC1967Proxy(address(oldImplementation), initializationData)));
    }

    function _config() internal view returns (UpgradeLendingPoolV1_2.UpgradeConfig memory) {
        return UpgradeLendingPoolV1_2.UpgradeConfig({
            expectedChainId: block.chainid,
            lendingPoolProxy: address(pool),
            expectedCurrentImplementation: address(oldImplementation),
            expectedContractUpgradeAuthority: address(safe),
            expectedPendingUpgradeAuthority: address(0),
            trackedAccountSetIsComplete: true,
            trackedAccounts: _trackedAccounts()
        });
    }

    function _verificationConfig(UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation)
        internal
        view
        returns (VerifyLendingPoolV1_2Upgrade.VerificationConfig memory)
    {
        return VerifyLendingPoolV1_2Upgrade.VerificationConfig({
            expectedChainId: block.chainid,
            lendingPoolProxy: address(pool),
            expectedOldImplementation: address(oldImplementation),
            expectedNewImplementation: prepared.newImplementation,
            expectedNewImplementationCodeHash: prepared.newImplementationCodeHash,
            expectedContractUpgradeAuthority: prepared.expectedContractUpgradeAuthority,
            expectedPendingUpgradeAuthority: prepared.expectedPendingUpgradeAuthority,
            trackedAccountSetIsComplete: prepared.preUpgradeState.trackedAccountSetIsComplete,
            trackedAccounts: _trackedAccounts(),
            expectedActivationTimestamp: activation,
            expectedPreUpgradeStateHash: prepared.preUpgradeStateHash,
            expectedTrackedAccountCommitment: prepared.trackedAccountCommitment,
            preparedTarget: prepared.target,
            preparedValue: prepared.value,
            preparedData: prepared.data,
            expectedPreparedPayloadFingerprint: prepared.payloadFingerprint,
            trustedPreparationAttestationDigest: prepared.preparationAttestationDigest
        });
    }

    function _validatePayload(
        address expectedProxy,
        address expectedSafe,
        address candidate,
        address target,
        uint256 value,
        bytes memory data
    ) internal view {
        upgrader.validatePreparedSafeTransaction(expectedProxy, expectedSafe, candidate, target, value, data);
    }

    function _decodePayload(bytes memory data) internal pure returns (address implementation, bytes memory inner) {
        bytes memory arguments = new bytes(data.length - 4);
        for (uint256 i; i < arguments.length; ++i) {
            arguments[i] = data[i + 4];
        }
        return abi.decode(arguments, (address, bytes));
    }

    function _prefix(bytes memory source, uint256 length) internal pure returns (bytes memory result) {
        result = new bytes(length);
        for (uint256 i; i < length; ++i) {
            result[i] = source[i];
        }
    }

    function _assertMalformedVersion(bytes memory response) internal {
        V1_2RawVersionResponder responder = new V1_2RawVersionResponder(response);
        vm.expectRevert(abi.encodeWithSelector(UpgradeLendingPoolV1_2.VersionReadFailed.selector, address(responder)));
        upgrader.validateCanonicalVersion(address(responder));
        vm.expectRevert(
            abi.encodeWithSelector(VerifyLendingPoolV1_2Upgrade.VersionReadFailed.selector, address(responder))
        );
        verifier.validateCanonicalVersion(address(responder));
    }

    function _expectPostValueChange(UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation)
        internal
    {
        vm.expectPartialRevert(VerifyLendingPoolV1_2Upgrade.PostUpgradeValueChanged.selector);
        verifier.verifyPostUpgrade(_verificationConfig(prepared, activation), prepared.preUpgradeState);
    }

    function _expectAttestationMismatch(
        VerifyLendingPoolV1_2Upgrade.VerificationConfig memory config,
        LendingPoolV1_2UpgradeStateFingerprint.State memory state
    ) internal {
        bytes32 recomputed = _attestationDigest(config);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyLendingPoolV1_2Upgrade.PreparationAttestationDigestMismatch.selector,
                config.trustedPreparationAttestationDigest,
                recomputed
            )
        );
        verifier.verifyPostUpgrade(config, state);
    }

    function _replaceTrustedAttestationDigest(VerifyLendingPoolV1_2Upgrade.VerificationConfig memory config)
        internal
        pure
    {
        // Test-only deliberate trust-root replacement reaches lower-layer negative checks. Production operators must
        // preserve the authentic preparation digest independently and never recalculate it from replacement data.
        config.trustedPreparationAttestationDigest = _attestationDigest(config);
    }

    function _attestationDigest(VerifyLendingPoolV1_2Upgrade.VerificationConfig memory config)
        internal
        pure
        returns (bytes32)
    {
        return LendingPoolV1_2PreparationAttestation.calculate(
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
    }

    function _seedIncidentalTransferSource(uint256 collateralAmount, uint256 debtAmount, uint256 vaultShareAmount)
        internal
        returns (address dustSender)
    {
        dustSender = makeAddr("postPreparationIncidentalBalanceSender");
        collateralToken.mint(dustSender, collateralAmount + vaultShareAmount);
        debtToken.mint(dustSender, debtAmount);
        vm.startPrank(dustSender);
        collateralToken.approve(address(vault), vaultShareAmount);
        vault.deposit(vaultShareAmount, dustSender);
        vm.stopPrank();
    }

    function _transferIncidentalBalances(
        address dustSender,
        address implementation,
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 vaultShareAmount
    ) internal {
        vm.startPrank(dustSender);
        assertTrue(collateralToken.transfer(implementation, collateralAmount));
        assertTrue(debtToken.transfer(implementation, debtAmount));
        assertTrue(vault.transfer(implementation, vaultShareAmount));
        vm.stopPrank();
    }

    function _assertIncidentalDelta(
        VerifyLendingPoolV1_2Upgrade.ImplementationIncidentalBalanceDelta memory delta,
        address implementation,
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 vaultShareAmount
    ) internal pure {
        assertEq(delta.preparationTime.implementation, implementation);
        assertEq(delta.observedPostUpgrade.implementation, implementation);
        assertEq(delta.preparationTime.collateralAssetBalance, 0);
        assertEq(delta.preparationTime.debtAssetBalance, 0);
        assertEq(delta.preparationTime.vaultShareBalance, 0);
        assertEq(delta.observedPostUpgrade.collateralAssetBalance, collateralAmount);
        assertEq(delta.observedPostUpgrade.debtAssetBalance, debtAmount);
        assertEq(delta.observedPostUpgrade.vaultShareBalance, vaultShareAmount);
        assertEq(delta.collateralAssetChanged, collateralAmount != 0);
        assertEq(delta.debtAssetChanged, debtAmount != 0);
        assertEq(delta.vaultShareChanged, vaultShareAmount != 0);
    }

    function _incrementMappingLeaf(address account, uint256 mappingSlot) internal {
        bytes32 leaf = keccak256(abi.encode(account, mappingSlot));
        vm.store(address(pool), leaf, bytes32(uint256(vm.load(address(pool), leaf)) + 1));
    }

    function _fundIncidentalBalances(address oldImplementationAddress, address predictedImplementation) internal {
        address dustSender = makeAddr("incidentalBalanceSender");
        collateralToken.mint(dustSender, 38);
        debtToken.mint(dustSender, 18);
        vm.startPrank(dustSender);
        collateralToken.approve(address(vault), 24);
        assertEq(vault.deposit(24, dustSender), 24);
        assertTrue(collateralToken.transfer(oldImplementationAddress, 3));
        assertTrue(debtToken.transfer(oldImplementationAddress, 5));
        assertTrue(vault.transfer(oldImplementationAddress, 7));
        assertTrue(collateralToken.transfer(predictedImplementation, 11));
        assertTrue(debtToken.transfer(predictedImplementation, 13));
        assertTrue(vault.transfer(predictedImplementation, 17));
        vm.stopPrank();
    }

    function _safeForward(bytes memory data) internal {
        safe.forward(address(pool), 0, data);
    }

    function _callAndBubble(address target, uint256 value, bytes memory data) internal {
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    function _implementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(pool), ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _addressWord(address value) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    function _rollbackDigest(UpgradeLendingPoolV1_2.PreparedTransaction memory prepared)
        internal
        view
        returns (bytes32 digest)
    {
        digest = keccak256(
            abi.encode(
                vm.load(address(pool), ERC1967_IMPLEMENTATION_SLOT),
                vm.load(address(pool), INITIALIZABLE_STORAGE),
                vm.load(address(pool), UPGRADE_AUTHORITY_STORAGE),
                vm.load(address(pool), bytes32(uint256(UPGRADE_AUTHORITY_STORAGE) + 1))
            )
        );
        for (uint256 slot; slot < 18; ++slot) {
            digest = keccak256(abi.encode(digest, vm.load(address(pool), bytes32(slot))));
        }
        address[] memory accounts = _trackedAccounts();
        for (uint256 i; i < accounts.length; ++i) {
            for (uint256 mappingSlot = 15; mappingSlot < 18; ++mappingSlot) {
                digest = keccak256(
                    abi.encode(digest, vm.load(address(pool), keccak256(abi.encode(accounts[i], mappingSlot))))
                );
            }
        }
        address[5] memory balanceAccounts = [address(pool), borrower, provider, address(safe), stranger];
        for (uint256 i; i < balanceAccounts.length; ++i) {
            address account = balanceAccounts[i];
            digest = keccak256(
                abi.encode(
                    digest, collateralToken.balanceOf(account), debtToken.balanceOf(account), vault.balanceOf(account)
                )
            );
        }
        digest = keccak256(
            abi.encode(
                digest,
                vault.totalAssets(),
                vault.totalSupply(),
                collateralToken.balanceOf(address(vault)),
                _implementationBalanceDigest(address(oldImplementation)),
                _implementationBalanceDigest(prepared.newImplementation)
            )
        );
    }

    function _implementationBalanceDigest(address implementation) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                collateralToken.balanceOf(implementation),
                debtToken.balanceOf(implementation),
                vault.balanceOf(implementation)
            )
        );
    }

    function _setRunEnvironment() internal {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_CHAIN_ID", vm.toString(block.chainid));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("LENDING_POOL_PROXY", vm.toString(address(pool)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_CURRENT_IMPLEMENTATION", vm.toString(address(oldImplementation)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_UPGRADE_AUTHORITY", vm.toString(address(safe)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_PENDING_UPGRADE_AUTHORITY", vm.toString(address(0)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("TRACKED_ACCOUNT_SET_IS_COMPLETE", "true");
        address[] memory accounts = _trackedAccounts();
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("TRACKED_ACCOUNTS", string.concat(vm.toString(accounts[0]), ",", vm.toString(accounts[1])));
    }

    function _setVerifierEnvironment(UpgradeLendingPoolV1_2.PreparedTransaction memory prepared, uint256 activation)
        internal
    {
        _setRunEnvironment();
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_OLD_IMPLEMENTATION", vm.toString(address(oldImplementation)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_NEW_IMPLEMENTATION", vm.toString(prepared.newImplementation));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_NEW_IMPLEMENTATION_CODE_HASH", vm.toString(prepared.newImplementationCodeHash));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_V1_2_ACTIVATION_TIMESTAMP", vm.toString(activation));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_PRE_UPGRADE_STATE_HASH", vm.toString(prepared.preUpgradeStateHash));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_TRACKED_ACCOUNT_COMMITMENT", vm.toString(prepared.trackedAccountCommitment));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("PREPARED_TARGET", vm.toString(prepared.target));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("PREPARED_VALUE", vm.toString(prepared.value));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("PREPARED_CALLDATA", vm.toString(prepared.data));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_PREPARED_PAYLOAD_FINGERPRINT", vm.toString(prepared.payloadFingerprint));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("TRUSTED_PREPARATION_ATTESTATION_DIGEST", vm.toString(prepared.preparationAttestationDigest));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("PRE_UPGRADE_STATE_ABI", vm.toString(abi.encode(prepared.preUpgradeState)));
    }

    function _trackedAccounts() internal view returns (address[] memory accounts) {
        accounts = new address[](2);
        if (uint160(borrower) < uint160(provider)) {
            accounts[0] = borrower;
            accounts[1] = provider;
        } else {
            accounts[0] = provider;
            accounts[1] = borrower;
        }
    }
}
