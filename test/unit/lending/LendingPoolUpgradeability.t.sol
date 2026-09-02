// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {LendingPoolProxyFixture} from "../../helpers/LendingPoolProxyFixture.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";

import {LendingPool} from "../../../src/core/lending/LendingPool.sol";
import {CollateralVault} from "../../../src/core/vault/CollateralVault.sol";

contract LendingPoolUpgradeabilityTest is Test, LendingPoolProxyFixture {
    event UpgradeAuthorityTransferStarted(address indexed currentAuthority, address indexed pendingAuthority);
    event UpgradeAuthorityTransferred(address indexed previousAuthority, address indexed newAuthority);

    string internal constant AUTHORITY_NAMESPACE = "lending.protocol.storage.LendingPoolUpgradeAuthority";
    string internal constant INITIALIZABLE_NAMESPACE = "openzeppelin.storage.Initializable";

    bytes32 internal constant LOCKED_AUTHORITY_ROOT =
        0x8000ce11f38414f298b74975bfaea500fcdbebb431834e96f66ac2883c9bb800;
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant LTV_BPS = 7_000;
    uint256 internal constant LIQUIDATION_THRESHOLD_BPS = 8_000;
    uint256 internal constant LIQUIDATION_BONUS_BPS = 500;
    uint256 internal constant MAX_PRICE_STALENESS = 1 days;
    uint256 internal constant BASE_BORROW_RATE = 0.05e18;
    uint256 internal constant BORROW_RATE_SLOPE = 0.2e18;

    MockERC20 internal collateralToken;
    MockERC20 internal debtToken;
    MockV3Aggregator internal priceFeed;
    CollateralVault internal vault;
    LendingPool internal implementation;
    LendingPool internal pool;

    address internal proxyDeployer;
    address internal activeAuthority;
    address internal pendingAuthority;
    address internal replacementPendingAuthority;
    address internal unrelatedCaller;
    address internal collateralDepositor;
    address internal liquidityProvider;

    uint256 internal initializationTimestamp;

    function setUp() public {
        proxyDeployer = address(this);
        activeAuthority = makeAddr("activeAuthority");
        pendingAuthority = makeAddr("pendingAuthority");
        replacementPendingAuthority = makeAddr("replacementPendingAuthority");
        unrelatedCaller = makeAddr("unrelatedCaller");
        collateralDepositor = makeAddr("collateralDepositor");
        liquidityProvider = makeAddr("liquidityProvider");

        collateralToken = new MockERC20("Collateral Token", "COL");
        debtToken = new MockERC20("Debt Token", "DEBT");
        vault = new CollateralVault("Collateral Vault Share", "CVS", collateralToken);
        priceFeed = new MockV3Aggregator(8, 1e8, block.timestamp);

        implementation = new LendingPool();
        initializationTimestamp = block.timestamp;
        pool = _deployLendingPoolProxy(implementation, _proxyConfig(activeAuthority));
    }

    function test_ImplementationInitializeRevertsBecauseInitializersAreDisabled() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _initialize(implementation, activeAuthority);
    }

    function test_ProxyDeploymentAtomicallyInitializesAllConfigurationAndAuthorityState() public view {
        assertNotEq(address(pool), address(implementation));
        assertGt(address(pool).code.length, 0);
        assertGt(address(implementation).code.length, 0);
        assertEq(_storedAddress(address(pool), ERC1967_IMPLEMENTATION_SLOT), address(implementation));

        assertEq(address(pool.priceFeed()), address(priceFeed));
        assertEq(address(pool.vault()), address(vault));
        assertEq(address(pool.debtAsset()), address(debtToken));
        assertEq(pool.maxPriceStaleness(), MAX_PRICE_STALENESS);
        assertEq(pool.ltvBps(), LTV_BPS);
        assertEq(pool.liquidationThresholdBps(), LIQUIDATION_THRESHOLD_BPS);
        assertEq(pool.liquidationBonusBps(), LIQUIDATION_BONUS_BPS);
        assertEq(pool.baseBorrowRate(), BASE_BORROW_RATE);
        assertEq(pool.borrowRateSlope(), BORROW_RATE_SLOPE);

        assertEq(address(pool.collateralAsset()), address(collateralToken));
        assertEq(pool.borrowIndex(), WAD);
        assertEq(pool.lastBorrowIndexUpdate(), initializationTimestamp);
        assertEq(pool.upgradeAuthority(), activeAuthority);
        assertEq(pool.pendingUpgradeAuthority(), address(0));
    }

    function test_ProxyInitializeRevertsAfterAtomicInitialization() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _initialize(pool, activeAuthority);
    }

    function test_ProxyConstructionRevertsAtomicallyForZeroInitialUpgradeAuthority() public {
        uint64 deployerNonce = vm.getNonce(proxyDeployer);
        address predictedProxy = vm.computeCreateAddress(proxyDeployer, deployerNonce);

        vm.expectRevert(abi.encodeWithSelector(LendingPool.InvalidUpgradeAuthority.selector, address(0)));
        _deployLendingPoolProxy(implementation, _proxyConfig(address(0)));

        assertEq(predictedProxy.code.length, 0);
    }

    function test_ProxyDeployerAndConfiguredAuthorityAreDistinctAndOnlyConfiguredAuthorityIsActive() public {
        assertNotEq(proxyDeployer, activeAuthority);
        assertEq(pool.upgradeAuthority(), activeAuthority);

        vm.expectRevert(abi.encodeWithSelector(LendingPool.UnauthorizedUpgradeAuthority.selector, proxyDeployer));
        pool.proposeUpgradeAuthority(pendingAuthority);
    }

    function test_AuthorityGettersReturnConfiguredAuthorityAndZeroPendingSentinel() public view {
        assertEq(pool.upgradeAuthority(), activeAuthority);
        assertEq(pool.pendingUpgradeAuthority(), address(0));
    }

    function test_UnrelatedCallerCannotProposeUpgradeAuthority() public {
        vm.prank(unrelatedCaller);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.UnauthorizedUpgradeAuthority.selector, unrelatedCaller));
        pool.proposeUpgradeAuthority(pendingAuthority);
    }

    function test_ActiveAuthorityCannotProposeZeroAddress() public {
        vm.prank(activeAuthority);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InvalidUpgradeAuthority.selector, address(0)));
        pool.proposeUpgradeAuthority(address(0));
    }

    function test_ValidProposalStoresPendingAuthorityAndEmitsTransferStarted() public {
        vm.expectEmit(true, true, false, true, address(pool));
        emit UpgradeAuthorityTransferStarted(activeAuthority, pendingAuthority);

        vm.prank(activeAuthority);
        pool.proposeUpgradeAuthority(pendingAuthority);

        assertEq(pool.pendingUpgradeAuthority(), pendingAuthority);
    }

    function test_LaterProposalReplacesPendingAuthorityAndReplacedNomineeCannotAccept() public {
        vm.prank(activeAuthority);
        pool.proposeUpgradeAuthority(pendingAuthority);

        vm.prank(activeAuthority);
        pool.proposeUpgradeAuthority(replacementPendingAuthority);

        assertEq(pool.pendingUpgradeAuthority(), replacementPendingAuthority);

        vm.prank(pendingAuthority);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.NotPendingUpgradeAuthority.selector, pendingAuthority));
        pool.acceptUpgradeAuthority();
    }

    function test_PendingAuthorityCannotPerformAuthorityOnlyProposalBeforeAcceptance() public {
        vm.prank(activeAuthority);
        pool.proposeUpgradeAuthority(pendingAuthority);

        vm.prank(pendingAuthority);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.UnauthorizedUpgradeAuthority.selector, pendingAuthority));
        pool.proposeUpgradeAuthority(replacementPendingAuthority);
    }

    function test_NonPendingCallerCannotAcceptUpgradeAuthority() public {
        vm.prank(activeAuthority);
        pool.proposeUpgradeAuthority(pendingAuthority);

        vm.prank(unrelatedCaller);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.NotPendingUpgradeAuthority.selector, unrelatedCaller));
        pool.acceptUpgradeAuthority();
    }

    function test_PendingAuthorityAcceptanceEmitsTransferAndUpdatesAuthorityState() public {
        vm.prank(activeAuthority);
        pool.proposeUpgradeAuthority(pendingAuthority);

        vm.expectEmit(true, true, false, true, address(pool));
        emit UpgradeAuthorityTransferred(activeAuthority, pendingAuthority);

        vm.prank(pendingAuthority);
        pool.acceptUpgradeAuthority();

        assertEq(pool.upgradeAuthority(), pendingAuthority);
        assertEq(pool.pendingUpgradeAuthority(), address(0));
    }

    function test_FormerAuthorityLosesPermissionAndNewAuthorityCanPropose() public {
        vm.prank(activeAuthority);
        pool.proposeUpgradeAuthority(pendingAuthority);

        vm.prank(pendingAuthority);
        pool.acceptUpgradeAuthority();

        vm.prank(activeAuthority);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.UnauthorizedUpgradeAuthority.selector, activeAuthority));
        pool.proposeUpgradeAuthority(replacementPendingAuthority);

        vm.prank(pendingAuthority);
        pool.proposeUpgradeAuthority(replacementPendingAuthority);

        assertEq(pool.pendingUpgradeAuthority(), replacementPendingAuthority);
    }

    function test_ZeroAddressCanNeverBecomeActiveThroughProposalOrAcceptance() public {
        vm.prank(activeAuthority);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InvalidUpgradeAuthority.selector, address(0)));
        pool.proposeUpgradeAuthority(address(0));

        assertEq(pool.upgradeAuthority(), activeAuthority);
        assertEq(pool.pendingUpgradeAuthority(), address(0));

        vm.prank(activeAuthority);
        pool.proposeUpgradeAuthority(pendingAuthority);

        vm.prank(pendingAuthority);
        pool.acceptUpgradeAuthority();

        assertEq(pool.upgradeAuthority(), pendingAuthority);
        assertNotEq(pool.upgradeAuthority(), address(0));
        assertEq(pool.pendingUpgradeAuthority(), address(0));
    }

    function test_NoRenounceUpgradeAuthorityFunctionIsCallable() public {
        vm.prank(activeAuthority);
        (bool success,) = address(pool).call(abi.encodeWithSignature("renounceUpgradeAuthority()"));

        assertFalse(success);
        assertEq(pool.upgradeAuthority(), activeAuthority);
        assertEq(pool.pendingUpgradeAuthority(), address(0));
    }

    function test_AuthorityNamespaceRootMatchesERC7201FormulaAndDoesNotCollide() public pure {
        bytes32 authorityRoot = _erc7201Root(AUTHORITY_NAMESPACE);
        bytes32 initializableRoot = _erc7201Root(INITIALIZABLE_NAMESPACE);

        assertEq(authorityRoot, LOCKED_AUTHORITY_ROOT);
        assertNotEq(authorityRoot, ERC1967_IMPLEMENTATION_SLOT);
        assertNotEq(authorityRoot, initializableRoot);

        for (uint256 slot; slot < 18; ++slot) {
            assertNotEq(authorityRoot, bytes32(slot));
        }
    }

    function test_RawAuthorityStorageTracksProposalAndAcceptanceAtExpectedSlots() public {
        bytes32 authorityRoot = _erc7201Root(AUTHORITY_NAMESPACE);
        bytes32 pendingSlot = bytes32(uint256(authorityRoot) + 1);

        bytes32 activeBefore = vm.load(address(pool), authorityRoot);
        bytes32 pendingBefore = vm.load(address(pool), pendingSlot);

        assertEq(_addressFromWord(activeBefore), activeAuthority);
        assertEq(_addressFromWord(pendingBefore), address(0));

        vm.prank(activeAuthority);
        pool.proposeUpgradeAuthority(pendingAuthority);

        assertEq(vm.load(address(pool), authorityRoot), activeBefore);
        assertEq(_storedAddress(address(pool), pendingSlot), pendingAuthority);

        vm.prank(pendingAuthority);
        pool.acceptUpgradeAuthority();

        assertEq(_storedAddress(address(pool), authorityRoot), pendingAuthority);
        assertEq(vm.load(address(pool), pendingSlot), bytes32(0));
    }

    function test_AuthorityTransitionsPreserveEveryLegacySlot() public {
        bytes32[18] memory legacySlotsBefore;

        for (uint256 slot; slot < legacySlotsBefore.length; ++slot) {
            legacySlotsBefore[slot] = vm.load(address(pool), bytes32(slot));
        }

        vm.prank(activeAuthority);
        pool.proposeUpgradeAuthority(pendingAuthority);

        vm.prank(pendingAuthority);
        pool.acceptUpgradeAuthority();

        for (uint256 slot; slot < legacySlotsBefore.length; ++slot) {
            assertEq(vm.load(address(pool), bytes32(slot)), legacySlotsBefore[slot]);
        }
    }

    function test_ProxyOwnsProtocolAssetsWhileImplementationOwnsNoCustody() public {
        uint256 collateralAmount = 100 ether;
        uint256 liquidityAmount = 75 ether;
        uint256 expectedVaultShares = vault.previewDeposit(collateralAmount);

        collateralToken.mint(collateralDepositor, collateralAmount);
        vm.prank(collateralDepositor);
        collateralToken.approve(address(pool), collateralAmount);
        vm.prank(collateralDepositor);
        pool.depositCollateral(collateralAmount);

        debtToken.mint(liquidityProvider, liquidityAmount);
        vm.prank(liquidityProvider);
        debtToken.approve(address(pool), liquidityAmount);
        vm.prank(liquidityProvider);
        pool.depositLiquidity(liquidityAmount);

        assertGt(expectedVaultShares, 0);
        assertEq(pool.collateralSharesOf(collateralDepositor), expectedVaultShares);
        assertEq(pool.totalCollateralShares(), expectedVaultShares);
        assertEq(vault.balanceOf(address(pool)), expectedVaultShares);
        assertEq(debtToken.balanceOf(address(pool)), liquidityAmount);
        assertEq(collateralToken.balanceOf(address(pool)), 0);

        assertEq(vault.balanceOf(address(implementation)), 0);
        assertEq(collateralToken.balanceOf(address(implementation)), 0);
        assertEq(debtToken.balanceOf(address(implementation)), 0);
        assertEq(collateralToken.allowance(address(implementation), address(vault)), 0);
    }

    function _proxyConfig(address authority) internal view returns (LendingPoolProxyConfig memory) {
        return LendingPoolProxyConfig({
            priceFeed: address(priceFeed),
            vault: address(vault),
            debtAsset: address(debtToken),
            maxPriceStaleness: MAX_PRICE_STALENESS,
            ltvBps: LTV_BPS,
            liquidationThresholdBps: LIQUIDATION_THRESHOLD_BPS,
            liquidationBonusBps: LIQUIDATION_BONUS_BPS,
            baseBorrowRate: BASE_BORROW_RATE,
            borrowRateSlope: BORROW_RATE_SLOPE,
            initialUpgradeAuthority: authority
        });
    }

    function _initialize(LendingPool target, address authority) internal {
        target.initialize(
            address(priceFeed),
            address(vault),
            address(debtToken),
            MAX_PRICE_STALENESS,
            LTV_BPS,
            LIQUIDATION_THRESHOLD_BPS,
            LIQUIDATION_BONUS_BPS,
            BASE_BORROW_RATE,
            BORROW_RATE_SLOPE,
            authority
        );
    }

    function _erc7201Root(string memory namespace) internal pure returns (bytes32) {
        uint256 namespaceHashMinusOne = uint256(keccak256(bytes(namespace))) - 1;
        return bytes32(uint256(keccak256(abi.encode(namespaceHashMinusOne))) & ~uint256(0xff));
    }

    function _storedAddress(address target, bytes32 slot) internal view returns (address) {
        return _addressFromWord(vm.load(target, slot));
    }

    function _addressFromWord(bytes32 word) internal pure returns (address) {
        return address(uint160(uint256(word)));
    }
}
