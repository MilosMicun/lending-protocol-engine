// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {DeployLendingPoolV1} from "../../script/DeployLendingPoolV1.s.sol";
import {UpgradeLendingPoolV1_1} from "../../script/UpgradeLendingPoolV1_1.s.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {WrongUUIDImplementation} from "../mocks/WrongUUIDImplementation.sol";

import {LendingPool} from "../../src/core/lending/LendingPool.sol";
import {LendingPoolV1_1} from "../../src/core/lending/LendingPoolV1_1.sol";
import {CollateralVault} from "../../src/core/vault/CollateralVault.sol";

contract UpgradeLendingPoolV1_1Test is Test {
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 internal constant MAX_PRICE_STALENESS = 1 days;
    uint256 internal constant LTV_BPS = 7_000;
    uint256 internal constant LIQUIDATION_THRESHOLD_BPS = 8_000;
    uint256 internal constant LIQUIDATION_BONUS_BPS = 500;
    uint256 internal constant BASE_BORROW_RATE = 0.05e18;
    uint256 internal constant BORROW_RATE_SLOPE = 0.2e18;

    DeployLendingPoolV1 internal deployer;
    UpgradeLendingPoolV1_1 internal upgrader;
    MockERC20 internal collateralToken;
    MockERC20 internal debtToken;
    MockV3Aggregator internal priceFeed;
    CollateralVault internal vault;
    LendingPool internal v1Implementation;
    ERC1967Proxy internal proxy;
    LendingPool internal pool;

    address internal activeAuthority;
    address internal pendingAuthority;
    address internal nonAuthority;
    address internal borrower;
    address internal liquidityProvider;

    function setUp() public {
        deployer = new DeployLendingPoolV1();
        upgrader = new UpgradeLendingPoolV1_1();
        collateralToken = new MockERC20("Collateral Token", "COL");
        debtToken = new MockERC20("Debt Token", "DEBT");
        priceFeed = new MockV3Aggregator(8, 1e8, block.timestamp);

        activeAuthority = makeAddr("activeAuthority");
        pendingAuthority = makeAddr("pendingAuthority");
        nonAuthority = makeAddr("nonAuthority");
        borrower = makeAddr("borrower");
        liquidityProvider = makeAddr("liquidityProvider");

        (vault, v1Implementation, proxy, pool) = deployer.deploy(_deploymentConfig());
    }

    function test_UpgradeDeploysV1_1AndUpgradesExpectedProxyFromExpectedV1() public {
        UpgradeLendingPoolV1_1.UpgradeConfig memory config = _upgradeConfig(address(0));

        assertEq(_implementationWord(), _addressWord(address(v1Implementation)));
        address proxyBefore = address(pool);

        upgrader.validatePreUpgrade(config);
        UpgradeLendingPoolV1_1.UpgradeSnapshot memory beforeUpgrade = upgrader.snapshot(address(pool));
        UpgradeLendingPoolV1_1.ImplementationCustodySnapshot memory oldImplementationCustody =
            upgrader.snapshotImplementationCustody(beforeUpgrade.configuration, address(v1Implementation));

        uint64 nonceBefore = vm.getNonce(address(upgrader));
        LendingPoolV1_1 newImplementation = upgrader.deployV11(config);
        UpgradeLendingPoolV1_1.ImplementationCustodySnapshot memory newImplementationCustody =
            upgrader.snapshotImplementationCustody(beforeUpgrade.configuration, address(newImplementation));
        assertEq(vm.getNonce(address(upgrader)), nonceBefore + 1);
        assertGt(address(newImplementation).code.length, 0);
        assertNotEq(address(newImplementation), address(pool));
        assertNotEq(address(newImplementation), address(v1Implementation));

        bytes memory upgradeCall = upgrader.encodeUpgradeCall(address(newImplementation));
        assertEq(
            upgradeCall,
            abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, address(newImplementation), bytes(""))
        );

        vm.prank(activeAuthority);
        _executeEncodedUpgrade(upgradeCall);

        upgrader.validatePostUpgrade(
            config, beforeUpgrade, address(newImplementation), oldImplementationCustody, newImplementationCustody
        );
        assertEq(address(pool), proxyBefore);
        assertEq(_implementationWord(), _addressWord(address(newImplementation)));
        assertEq(LendingPoolV1_1(address(pool)).version(), "1.1");
    }

    function test_UpgradePreservesLegacySlotsAuthorityAccountingAndCustody() public {
        _buildRepresentativeState();

        vm.prank(activeAuthority);
        pool.proposeUpgradeAuthority(pendingAuthority);

        UpgradeLendingPoolV1_1.UpgradeConfig memory config = _upgradeConfig(pendingAuthority);
        upgrader.validatePreUpgrade(config);
        UpgradeLendingPoolV1_1.UpgradeSnapshot memory beforeUpgrade = upgrader.snapshot(address(pool));
        UpgradeLendingPoolV1_1.ImplementationCustodySnapshot memory oldImplementationCustody =
            upgrader.snapshotImplementationCustody(beforeUpgrade.configuration, address(v1Implementation));

        assertGt(beforeUpgrade.accounting.borrowIndex, 0);
        assertGt(beforeUpgrade.accounting.lastBorrowIndexUpdate, 0);
        assertGt(beforeUpgrade.accounting.totalCollateralShares, 0);
        assertGt(beforeUpgrade.accounting.totalLiquidity, 0);
        assertGt(beforeUpgrade.accounting.totalScaledDebt, 0);
        assertGt(beforeUpgrade.custody.proxyDebtAssetBalance, 0);
        assertGt(beforeUpgrade.custody.proxyVaultShareBalance, 0);
        assertGt(beforeUpgrade.custody.vaultTotalAssets, 0);
        assertGt(beforeUpgrade.custody.vaultTotalSupply, 0);
        assertGt(beforeUpgrade.custody.vaultCollateralAssetBalance, 0);

        LendingPoolV1_1 newImplementation = upgrader.deployV11(config);
        UpgradeLendingPoolV1_1.ImplementationCustodySnapshot memory newImplementationCustody =
            upgrader.snapshotImplementationCustody(beforeUpgrade.configuration, address(newImplementation));
        bytes memory upgradeCall = upgrader.encodeUpgradeCall(address(newImplementation));

        vm.prank(activeAuthority);
        _executeEncodedUpgrade(upgradeCall);

        upgrader.validatePostUpgrade(
            config, beforeUpgrade, address(newImplementation), oldImplementationCustody, newImplementationCustody
        );
        assertEq(pool.upgradeAuthority(), activeAuthority);
        assertEq(pool.pendingUpgradeAuthority(), pendingAuthority);
        assertEq(collateralToken.balanceOf(address(v1Implementation)), 0);
        assertEq(debtToken.balanceOf(address(v1Implementation)), 0);
        assertEq(vault.balanceOf(address(v1Implementation)), 0);
        assertEq(collateralToken.balanceOf(address(newImplementation)), 0);
        assertEq(debtToken.balanceOf(address(newImplementation)), 0);
        assertEq(vault.balanceOf(address(newImplementation)), 0);
    }

    function test_PreExistingImplementationDustDoesNotBlockUpgradeWhenBalancesArePreserved() public {
        _buildRepresentativeState();

        vm.prank(activeAuthority);
        pool.proposeUpgradeAuthority(pendingAuthority);

        address dustSender = makeAddr("dustSender");
        uint256 oldCollateralDust = 3;
        uint256 oldDebtDust = 5;
        uint256 oldVaultShareDust = 7;
        uint256 newCollateralDust = 11;
        uint256 newDebtDust = 13;
        uint256 newVaultShareDust = 17;

        collateralToken.mint(dustSender, oldCollateralDust + newCollateralDust + oldVaultShareDust + newVaultShareDust);
        debtToken.mint(dustSender, oldDebtDust + newDebtDust);

        vm.startPrank(dustSender);
        collateralToken.approve(address(vault), oldVaultShareDust + newVaultShareDust);
        uint256 mintedVaultShares = vault.deposit(oldVaultShareDust + newVaultShareDust, dustSender);
        assertEq(mintedVaultShares, oldVaultShareDust + newVaultShareDust);
        assertTrue(collateralToken.transfer(address(v1Implementation), oldCollateralDust));
        assertTrue(debtToken.transfer(address(v1Implementation), oldDebtDust));
        assertTrue(vault.transfer(address(v1Implementation), oldVaultShareDust));
        vm.stopPrank();

        UpgradeLendingPoolV1_1.UpgradeConfig memory config = _upgradeConfig(pendingAuthority);
        upgrader.validatePreUpgrade(config);
        UpgradeLendingPoolV1_1.UpgradeSnapshot memory beforeUpgrade = upgrader.snapshot(address(pool));
        UpgradeLendingPoolV1_1.ImplementationCustodySnapshot memory oldImplementationCustody =
            upgrader.snapshotImplementationCustody(beforeUpgrade.configuration, address(v1Implementation));
        uint256 proxyCollateralBalanceBefore = collateralToken.balanceOf(address(pool));

        LendingPoolV1_1 newImplementation = upgrader.deployV11(config);

        vm.startPrank(dustSender);
        assertTrue(collateralToken.transfer(address(newImplementation), newCollateralDust));
        assertTrue(debtToken.transfer(address(newImplementation), newDebtDust));
        assertTrue(vault.transfer(address(newImplementation), newVaultShareDust));
        vm.stopPrank();

        UpgradeLendingPoolV1_1.ImplementationCustodySnapshot memory newImplementationCustody =
            upgrader.snapshotImplementationCustody(beforeUpgrade.configuration, address(newImplementation));

        bytes memory upgradeCall = upgrader.encodeUpgradeCall(address(newImplementation));
        vm.prank(activeAuthority);
        _executeEncodedUpgrade(upgradeCall);

        upgrader.validatePostUpgrade(
            config, beforeUpgrade, address(newImplementation), oldImplementationCustody, newImplementationCustody
        );

        assertEq(_implementationWord(), _addressWord(address(newImplementation)));
        assertEq(LendingPoolV1_1(address(pool)).version(), "1.1");
        assertEq(collateralToken.balanceOf(address(v1Implementation)), oldCollateralDust);
        assertEq(debtToken.balanceOf(address(v1Implementation)), oldDebtDust);
        assertEq(vault.balanceOf(address(v1Implementation)), oldVaultShareDust);
        assertEq(collateralToken.balanceOf(address(newImplementation)), newCollateralDust);
        assertEq(debtToken.balanceOf(address(newImplementation)), newDebtDust);
        assertEq(vault.balanceOf(address(newImplementation)), newVaultShareDust);
        assertEq(collateralToken.balanceOf(address(pool)), proxyCollateralBalanceBefore);
        assertEq(debtToken.balanceOf(address(pool)), beforeUpgrade.custody.proxyDebtAssetBalance);
        assertEq(vault.balanceOf(address(pool)), beforeUpgrade.custody.proxyVaultShareBalance);
        assertEq(pool.upgradeAuthority(), activeAuthority);
        assertEq(pool.pendingUpgradeAuthority(), pendingAuthority);
    }

    function test_PostUpgradeValidationRejectsImplementationCustodyBalanceDelta() public {
        UpgradeLendingPoolV1_1.UpgradeConfig memory config = _upgradeConfig(address(0));
        upgrader.validatePreUpgrade(config);
        UpgradeLendingPoolV1_1.UpgradeSnapshot memory beforeUpgrade = upgrader.snapshot(address(pool));
        UpgradeLendingPoolV1_1.ImplementationCustodySnapshot memory oldImplementationCustody =
            upgrader.snapshotImplementationCustody(beforeUpgrade.configuration, address(v1Implementation));

        LendingPoolV1_1 newImplementation = upgrader.deployV11(config);
        UpgradeLendingPoolV1_1.ImplementationCustodySnapshot memory newImplementationCustody =
            upgrader.snapshotImplementationCustody(beforeUpgrade.configuration, address(newImplementation));

        bytes memory upgradeCall = upgrader.encodeUpgradeCall(address(newImplementation));
        vm.prank(activeAuthority);
        _executeEncodedUpgrade(upgradeCall);

        assertEq(_implementationWord(), _addressWord(address(newImplementation)));
        assertEq(LendingPoolV1_1(address(pool)).version(), "1.1");

        uint256 custodyChange = 1;
        debtToken.mint(address(newImplementation), custodyChange);

        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeLendingPoolV1_1.ImplementationCustodyBalanceChanged.selector,
                address(newImplementation),
                address(debtToken),
                newImplementationCustody.debtAssetBalance,
                newImplementationCustody.debtAssetBalance + custodyChange
            )
        );
        upgrader.validatePostUpgrade(
            config, beforeUpgrade, address(newImplementation), oldImplementationCustody, newImplementationCustody
        );
    }

    function test_PreflightRejectsZeroOrNonContractProxyBeforeDeployment() public {
        UpgradeLendingPoolV1_1.UpgradeConfig memory config = _upgradeConfig(address(0));

        config.lendingPoolProxy = address(0);
        _expectPreflightRevert(
            config, abi.encodeWithSelector(UpgradeLendingPoolV1_1.InvalidLendingPoolProxy.selector, address(0))
        );

        address nonContractProxy = makeAddr("nonContractProxy");
        config = _upgradeConfig(address(0));
        config.lendingPoolProxy = nonContractProxy;
        _expectPreflightRevert(
            config, abi.encodeWithSelector(UpgradeLendingPoolV1_1.LendingPoolProxyHasNoCode.selector, nonContractProxy)
        );
    }

    function test_PreflightRejectsUnexpectedCurrentImplementationBeforeDeployment() public {
        UpgradeLendingPoolV1_1.UpgradeConfig memory config = _upgradeConfig(address(0));

        config.expectedCurrentImplementation = address(0);
        _expectPreflightRevert(
            config,
            abi.encodeWithSelector(UpgradeLendingPoolV1_1.InvalidExpectedCurrentImplementation.selector, address(0))
        );

        address nonContractImplementation = makeAddr("nonContractImplementation");
        config = _upgradeConfig(address(0));
        config.expectedCurrentImplementation = nonContractImplementation;
        _expectPreflightRevert(
            config,
            abi.encodeWithSelector(
                UpgradeLendingPoolV1_1.ExpectedCurrentImplementationHasNoCode.selector, nonContractImplementation
            )
        );

        LendingPoolV1_1 differentImplementation = new LendingPoolV1_1();
        config = _upgradeConfig(address(0));
        config.expectedCurrentImplementation = address(differentImplementation);
        _expectPreflightRevert(
            config,
            abi.encodeWithSelector(
                UpgradeLendingPoolV1_1.UnexpectedCurrentImplementation.selector,
                _addressWord(address(differentImplementation)),
                _addressWord(address(v1Implementation))
            )
        );

        WrongUUIDImplementation wrongUuidImplementation = new WrongUUIDImplementation();
        ERC1967Proxy wrongUuidProxy = new ERC1967Proxy(
            address(wrongUuidImplementation), abi.encodeCall(WrongUUIDImplementation.proxiableUUID, ())
        );
        config = UpgradeLendingPoolV1_1.UpgradeConfig({
            lendingPoolProxy: address(wrongUuidProxy),
            expectedCurrentImplementation: address(wrongUuidImplementation),
            expectedUpgradeAuthority: activeAuthority,
            expectedPendingUpgradeAuthority: address(0),
            expectedChainId: block.chainid
        });
        _expectPreflightRevert(
            config,
            abi.encodeWithSelector(
                UpgradeLendingPoolV1_1.UnexpectedProxiableUUID.selector,
                address(wrongUuidImplementation),
                bytes32(uint256(1))
            )
        );
    }

    function test_PreflightRejectsUnexpectedActiveOrPendingAuthorityBeforeDeployment() public {
        UpgradeLendingPoolV1_1.UpgradeConfig memory config = _upgradeConfig(address(0));

        config.expectedUpgradeAuthority = address(0);
        _expectPreflightRevert(
            config, abi.encodeWithSelector(UpgradeLendingPoolV1_1.InvalidExpectedUpgradeAuthority.selector, address(0))
        );

        address unexpectedActiveAuthority = makeAddr("unexpectedActiveAuthority");
        config = _upgradeConfig(address(0));
        config.expectedUpgradeAuthority = unexpectedActiveAuthority;
        _expectPreflightRevert(
            config,
            abi.encodeWithSelector(
                UpgradeLendingPoolV1_1.UnexpectedActiveUpgradeAuthority.selector,
                unexpectedActiveAuthority,
                activeAuthority
            )
        );

        config = _upgradeConfig(pendingAuthority);
        _expectPreflightRevert(
            config,
            abi.encodeWithSelector(
                UpgradeLendingPoolV1_1.UnexpectedPendingUpgradeAuthority.selector, pendingAuthority, address(0)
            )
        );

        config = _upgradeConfig(address(0));
        config.expectedChainId = block.chainid + 1;
        _expectPreflightRevert(
            config,
            abi.encodeWithSelector(UpgradeLendingPoolV1_1.UnexpectedChainId.selector, block.chainid + 1, block.chainid)
        );
    }

    function test_NonAuthorityCannotExecuteUpgradeAndProxyStateRemainsUnchanged() public {
        _buildRepresentativeState();

        UpgradeLendingPoolV1_1.UpgradeConfig memory config = _upgradeConfig(address(0));
        upgrader.validatePreUpgrade(config);
        UpgradeLendingPoolV1_1.UpgradeSnapshot memory beforeUpgrade = upgrader.snapshot(address(pool));
        LendingPoolV1_1 newImplementation = upgrader.deployV11(config);
        bytes memory upgradeCall = upgrader.encodeUpgradeCall(address(newImplementation));

        vm.prank(nonAuthority);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.UnauthorizedUpgradeAuthority.selector, nonAuthority));
        _executeEncodedUpgrade(upgradeCall);

        assertEq(_implementationWord(), _addressWord(address(v1Implementation)));
        assertEq(pool.upgradeAuthority(), activeAuthority);
        assertEq(pool.pendingUpgradeAuthority(), address(0));
        upgrader.validatePreUpgrade(config);
        upgrader.validatePreservedState(beforeUpgrade);
    }

    function _buildRepresentativeState() internal {
        debtToken.mint(liquidityProvider, 1_000 ether);
        vm.prank(liquidityProvider);
        debtToken.approve(address(pool), type(uint256).max);
        vm.prank(liquidityProvider);
        pool.depositLiquidity(1_000 ether);

        collateralToken.mint(borrower, 500 ether);
        vm.prank(borrower);
        collateralToken.approve(address(pool), type(uint256).max);
        vm.prank(borrower);
        pool.depositCollateral(500 ether);
        vm.prank(borrower);
        pool.borrow(200 ether);

        assertGt(pool.liquidityBalanceOf(liquidityProvider), 0);
        assertGt(pool.collateralSharesOf(borrower), 0);
        assertGt(pool.scaledDebtOf(borrower), 0);
        assertGt(debtToken.balanceOf(address(pool)), 0);
        assertGt(vault.balanceOf(address(pool)), 0);
    }

    function _expectPreflightRevert(UpgradeLendingPoolV1_1.UpgradeConfig memory config, bytes memory expectedRevert)
        internal
    {
        uint64 nonceBefore = vm.getNonce(address(upgrader));

        vm.expectRevert(expectedRevert);
        upgrader.validatePreUpgrade(config);

        assertEq(vm.getNonce(address(upgrader)), nonceBefore);
    }

    function _executeEncodedUpgrade(bytes memory upgradeCall) internal {
        (bool success, bytes memory returnData) = address(pool).call(upgradeCall);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    function _deploymentConfig() internal view returns (DeployLendingPoolV1.DeploymentConfig memory) {
        return DeployLendingPoolV1.DeploymentConfig({
            collateralAsset: address(collateralToken),
            debtAsset: address(debtToken),
            priceFeed: address(priceFeed),
            collateralVaultName: "Collateral Vault Share",
            collateralVaultSymbol: "CVS",
            maxPriceStaleness: MAX_PRICE_STALENESS,
            ltvBps: LTV_BPS,
            liquidationThresholdBps: LIQUIDATION_THRESHOLD_BPS,
            liquidationBonusBps: LIQUIDATION_BONUS_BPS,
            baseBorrowRate: BASE_BORROW_RATE,
            borrowRateSlope: BORROW_RATE_SLOPE,
            initialUpgradeAuthority: activeAuthority,
            expectedChainId: block.chainid
        });
    }

    function _upgradeConfig(address expectedPendingAuthority)
        internal
        view
        returns (UpgradeLendingPoolV1_1.UpgradeConfig memory)
    {
        return UpgradeLendingPoolV1_1.UpgradeConfig({
            lendingPoolProxy: address(pool),
            expectedCurrentImplementation: address(v1Implementation),
            expectedUpgradeAuthority: activeAuthority,
            expectedPendingUpgradeAuthority: expectedPendingAuthority,
            expectedChainId: block.chainid
        });
    }

    function _implementationWord() internal view returns (bytes32) {
        return vm.load(address(pool), ERC1967_IMPLEMENTATION_SLOT);
    }

    function _addressWord(address value) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }
}
