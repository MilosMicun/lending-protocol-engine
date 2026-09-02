// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {LendingPoolProxyFixture} from "../../helpers/LendingPoolProxyFixture.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";
import {NonUUPSImplementation} from "../../mocks/NonUUPSImplementation.sol";
import {WrongUUIDImplementation} from "../../mocks/WrongUUIDImplementation.sol";

import {LendingPool} from "../../../src/core/lending/LendingPool.sol";
import {LendingPoolV1_1} from "../../../src/core/lending/LendingPoolV1_1.sol";
import {CollateralVault} from "../../../src/core/vault/CollateralVault.sol";

contract LendingPoolUpgradeTest is Test, LendingPoolProxyFixture {
    event Upgraded(address indexed implementation);

    struct ProxyStateSnapshot {
        address implementation;
        address activeAuthority;
        address pendingAuthority;
        address priceFeed;
        address vault;
        address debtAsset;
        address collateralAsset;
        uint256 maxPriceStaleness;
        uint256 ltvBps;
        uint256 liquidationThresholdBps;
        uint256 liquidationBonusBps;
        uint256 borrowIndex;
        uint256 lastBorrowIndexUpdate;
        uint256 baseBorrowRate;
        uint256 borrowRateSlope;
    }

    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant WRONG_UUID = bytes32(uint256(1));

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
    LendingPool internal pool;
    LendingPool internal v1Implementation;
    LendingPoolV1_1 internal v11Implementation;

    address internal proxyDeployer;
    address internal formerAuthority;
    address internal activeAuthority;
    address internal pendingAuthority;
    address internal unrelatedCaller;
    address internal eoaTarget;

    function setUp() public {
        proxyDeployer = address(this);
        formerAuthority = makeAddr("formerAuthority");
        activeAuthority = makeAddr("activeAuthority");
        pendingAuthority = makeAddr("pendingAuthority");
        unrelatedCaller = makeAddr("unrelatedCaller");
        eoaTarget = makeAddr("eoaTarget");

        collateralToken = new MockERC20("Collateral Token", "COL");
        debtToken = new MockERC20("Debt Token", "DEBT");
        vault = new CollateralVault("Collateral Vault Share", "CVS", collateralToken);
        priceFeed = new MockV3Aggregator(8, 1e8, block.timestamp);

        v1Implementation = new LendingPool();
        v11Implementation = new LendingPoolV1_1();
        pool = _deployLendingPoolProxy(v1Implementation, _proxyConfig(formerAuthority));

        vm.prank(formerAuthority);
        pool.proposeUpgradeAuthority(activeAuthority);
        vm.prank(activeAuthority);
        pool.acceptUpgradeAuthority();
        vm.prank(activeAuthority);
        pool.proposeUpgradeAuthority(pendingAuthority);
    }

    function test_ActiveAuthorityUpgradesRealProxyToV1_1AndPreservesConfigurationAndAuthority() public {
        ProxyStateSnapshot memory beforeState = _snapshotProxyState();
        address proxyAddress = address(pool);

        assertEq(beforeState.implementation, address(v1Implementation));
        assertNotEq(proxyAddress, address(v1Implementation));
        assertNotEq(proxyAddress, address(v11Implementation));
        assertNotEq(address(v1Implementation), address(v11Implementation));
        assertNotEq(proxyDeployer, activeAuthority);
        assertNotEq(activeAuthority, pendingAuthority);
        assertNotEq(activeAuthority, formerAuthority);
        assertNotEq(activeAuthority, unrelatedCaller);

        vm.prank(activeAuthority);
        pool.upgradeToAndCall(address(v11Implementation), "");

        assertEq(address(pool), proxyAddress);
        assertEq(_implementationAddress(), address(v11Implementation));
        assertEq(LendingPoolV1_1(proxyAddress).version(), "1.1");
        _assertProxyStateUnchanged(beforeState);
    }

    function test_SuccessfulUpgradeEmitsStandardERC1967UpgradedEvent() public {
        vm.expectEmit(true, false, false, true, address(pool));
        emit Upgraded(address(v11Implementation));

        vm.prank(activeAuthority);
        pool.upgradeToAndCall(address(v11Implementation), "");

        assertEq(_implementationAddress(), address(v11Implementation));
    }

    function test_UnrelatedCallerCannotUpgradeAndFailedAttemptPreservesProxyState() public {
        _expectUnauthorizedUpgradeAndUnchanged(unrelatedCaller);
    }

    function test_ProxyDeployerCannotUpgradeAndFailedAttemptPreservesProxyState() public {
        assertNotEq(proxyDeployer, activeAuthority);
        _expectUnauthorizedUpgradeAndUnchanged(proxyDeployer);
    }

    function test_PendingAuthorityCannotUpgradeBeforeAcceptanceAndFailedAttemptPreservesProxyState() public {
        assertEq(pool.pendingUpgradeAuthority(), pendingAuthority);
        _expectUnauthorizedUpgradeAndUnchanged(pendingAuthority);
    }

    function test_AfterAcceptedTransferFormerAuthorityCannotUpgradeButNewActiveAuthorityCan() public {
        assertEq(pool.upgradeAuthority(), activeAuthority);
        assertEq(pool.pendingUpgradeAuthority(), pendingAuthority);

        _expectUnauthorizedUpgradeAndUnchanged(formerAuthority);

        vm.prank(activeAuthority);
        pool.upgradeToAndCall(address(v11Implementation), "");

        assertEq(_implementationAddress(), address(v11Implementation));
        assertEq(LendingPoolV1_1(address(pool)).version(), "1.1");
    }

    function test_DirectUpgradeCallsOnV1AndV1_1ImplementationsFailProxyContextGuard() public {
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        v1Implementation.upgradeToAndCall(address(v11Implementation), "");

        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        v11Implementation.upgradeToAndCall(address(v1Implementation), "");
    }

    function test_ProxiableUUIDThroughProxyFailsDelegateCallContextGuard() public {
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        pool.proxiableUUID();
    }

    function test_DirectProxiableUUIDOnV1AndV1_1ReturnsERC1967ImplementationSlot() public view {
        assertEq(v1Implementation.proxiableUUID(), ERC1967_IMPLEMENTATION_SLOT);
        assertEq(v11Implementation.proxiableUUID(), ERC1967_IMPLEMENTATION_SLOT);
    }

    function test_UpgradeToZeroAddressRevertsAndPreservesProxyState() public {
        _expectEmptyRevertAndUnchanged(address(0));
    }

    function test_UpgradeToEOARevertsAndPreservesProxyState() public {
        assertEq(eoaTarget.code.length, 0);
        _expectEmptyRevertAndUnchanged(eoaTarget);
    }

    function test_UpgradeToNonUUPSImplementationRevertsAndPreservesProxyState() public {
        NonUUPSImplementation nonUupsImplementation = new NonUUPSImplementation();

        assertGt(address(nonUupsImplementation).code.length, 0);
        _expectInvalidImplementationAndUnchanged(address(nonUupsImplementation));
    }

    function test_UpgradeToWrongUUIDImplementationRevertsAndPreservesProxyState() public {
        WrongUUIDImplementation wrongUuidImplementation = new WrongUUIDImplementation();
        ProxyStateSnapshot memory beforeState = _snapshotProxyState();

        vm.prank(activeAuthority);
        vm.expectRevert(abi.encodeWithSelector(UUPSUpgradeable.UUPSUnsupportedProxiableUUID.selector, WRONG_UUID));
        pool.upgradeToAndCall(address(wrongUuidImplementation), "");

        _assertProxyStateExactly(beforeState);
    }

    function _expectEmptyRevertAndUnchanged(address invalidImplementation) internal {
        ProxyStateSnapshot memory beforeState = _snapshotProxyState();

        vm.prank(activeAuthority);
        (bool success, bytes memory revertData) = address(pool)
            .call(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, invalidImplementation, bytes("")));

        assertFalse(success);
        assertEq(revertData.length, 0);
        _assertProxyStateExactly(beforeState);
    }

    function _expectUnauthorizedUpgradeAndUnchanged(address caller) internal {
        ProxyStateSnapshot memory beforeState = _snapshotProxyState();

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.UnauthorizedUpgradeAuthority.selector, caller));
        pool.upgradeToAndCall(address(v11Implementation), "");

        _assertProxyStateExactly(beforeState);
    }

    function _expectInvalidImplementationAndUnchanged(address invalidImplementation) internal {
        ProxyStateSnapshot memory beforeState = _snapshotProxyState();

        vm.prank(activeAuthority);
        vm.expectRevert(
            abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, invalidImplementation)
        );
        pool.upgradeToAndCall(invalidImplementation, "");

        _assertProxyStateExactly(beforeState);
    }

    function _snapshotProxyState() internal view returns (ProxyStateSnapshot memory snapshot) {
        snapshot = ProxyStateSnapshot({
            implementation: _implementationAddress(),
            activeAuthority: pool.upgradeAuthority(),
            pendingAuthority: pool.pendingUpgradeAuthority(),
            priceFeed: address(pool.priceFeed()),
            vault: address(pool.vault()),
            debtAsset: address(pool.debtAsset()),
            collateralAsset: address(pool.collateralAsset()),
            maxPriceStaleness: pool.maxPriceStaleness(),
            ltvBps: pool.ltvBps(),
            liquidationThresholdBps: pool.liquidationThresholdBps(),
            liquidationBonusBps: pool.liquidationBonusBps(),
            borrowIndex: pool.borrowIndex(),
            lastBorrowIndexUpdate: pool.lastBorrowIndexUpdate(),
            baseBorrowRate: pool.baseBorrowRate(),
            borrowRateSlope: pool.borrowRateSlope()
        });
    }

    function _assertProxyStateExactly(ProxyStateSnapshot memory expected) internal view {
        assertEq(_implementationAddress(), expected.implementation);
        _assertProxyStateUnchanged(expected);
    }

    function _assertProxyStateUnchanged(ProxyStateSnapshot memory expected) internal view {
        assertEq(pool.upgradeAuthority(), expected.activeAuthority);
        assertEq(pool.pendingUpgradeAuthority(), expected.pendingAuthority);
        assertEq(address(pool.priceFeed()), expected.priceFeed);
        assertEq(address(pool.vault()), expected.vault);
        assertEq(address(pool.debtAsset()), expected.debtAsset);
        assertEq(address(pool.collateralAsset()), expected.collateralAsset);
        assertEq(pool.maxPriceStaleness(), expected.maxPriceStaleness);
        assertEq(pool.ltvBps(), expected.ltvBps);
        assertEq(pool.liquidationThresholdBps(), expected.liquidationThresholdBps);
        assertEq(pool.liquidationBonusBps(), expected.liquidationBonusBps);
        assertEq(pool.borrowIndex(), expected.borrowIndex);
        assertEq(pool.lastBorrowIndexUpdate(), expected.lastBorrowIndexUpdate);
        assertEq(pool.baseBorrowRate(), expected.baseBorrowRate);
        assertEq(pool.borrowRateSlope(), expected.borrowRateSlope);
    }

    function _implementationAddress() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(pool), ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _proxyConfig(address initialAuthority) internal view returns (LendingPoolProxyConfig memory) {
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
            initialUpgradeAuthority: initialAuthority
        });
    }
}
