// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {DeployLendingPoolV1} from "../../script/DeployLendingPoolV1.s.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

import {LendingPool} from "../../src/core/lending/LendingPool.sol";
import {CollateralVault} from "../../src/core/vault/CollateralVault.sol";

contract DeployLendingPoolV1Test is Test {
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_PRICE_STALENESS = 1 days;
    uint256 internal constant LTV_BPS = 7_000;
    uint256 internal constant LIQUIDATION_THRESHOLD_BPS = 8_000;
    uint256 internal constant LIQUIDATION_BONUS_BPS = 500;
    uint256 internal constant BASE_BORROW_RATE = 0.05e18;
    uint256 internal constant BORROW_RATE_SLOPE = 0.2e18;

    DeployLendingPoolV1 internal deployer;
    MockERC20 internal collateralToken;
    MockERC20 internal debtToken;
    MockV3Aggregator internal priceFeed;

    address internal broadcaster;
    address internal initialUpgradeAuthority;
    address internal proposedUpgradeAuthority;

    function setUp() public {
        deployer = new DeployLendingPoolV1();
        collateralToken = new MockERC20("Collateral Token", "COL");
        debtToken = new MockERC20("Debt Token", "DEBT");
        priceFeed = new MockV3Aggregator(8, 1e8, block.timestamp);

        broadcaster = makeAddr("broadcaster");
        initialUpgradeAuthority = makeAddr("initialUpgradeAuthority");
        proposedUpgradeAuthority = makeAddr("proposedUpgradeAuthority");
    }

    function test_DeployCreatesVaultImplementationAndAtomicallyInitializedRealProxy() public {
        DeployLendingPoolV1.DeploymentConfig memory config = _validConfig();
        uint256 initializationTimestamp = block.timestamp;

        (CollateralVault vault, LendingPool implementation, ERC1967Proxy proxy, LendingPool pool) =
            _deployAsBroadcaster(config);

        assertNotEq(address(vault), address(implementation));
        assertNotEq(address(vault), address(proxy));
        assertNotEq(address(implementation), address(proxy));
        assertGt(address(vault).code.length, 0);
        assertGt(address(implementation).code.length, 0);
        assertGt(address(proxy).code.length, 0);
        assertEq(_storedAddress(address(proxy), ERC1967_IMPLEMENTATION_SLOT), address(implementation));

        _assertInitializationData(config, address(vault));

        _assertInitializedConfiguration(pool, vault, config, initializationTimestamp);
        assertEq(vault.asset(), address(collateralToken));
        assertEq(vault.name(), config.collateralVaultName);
        assertEq(vault.symbol(), config.collateralVaultSymbol);
        assertEq(address(pool.vault()), address(vault));

        assertEq(pool.totalCollateralShares(), 0);
        assertEq(pool.totalLiquidity(), 0);
        assertEq(pool.totalScaledDebt(), 0);
        assertEq(pool.collateralSharesOf(broadcaster), 0);
        assertEq(pool.liquidityBalanceOf(broadcaster), 0);
        assertEq(pool.scaledDebtOf(broadcaster), 0);
        assertEq(collateralToken.balanceOf(address(pool)), 0);
        assertEq(debtToken.balanceOf(address(pool)), 0);
        assertEq(vault.balanceOf(address(pool)), 0);
        assertEq(collateralToken.allowance(address(pool), address(vault)), 0);
        assertEq(collateralToken.balanceOf(address(implementation)), 0);
        assertEq(debtToken.balanceOf(address(implementation)), 0);
        assertEq(vault.balanceOf(address(implementation)), 0);
        assertEq(collateralToken.allowance(address(implementation), address(vault)), 0);

        (bool proxiableSuccess,) = address(vault).call(abi.encodeWithSignature("proxiableUUID()"));
        assertFalse(proxiableSuccess);
        (bool upgradeSuccess,) =
            address(vault).call(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(implementation), ""));
        assertFalse(upgradeSuccess);
    }

    function test_DeployUsesOnlyExplicitUpgradeAuthorityAndDoesNotAuthorizeDeployer() public {
        DeployLendingPoolV1.DeploymentConfig memory config = _validConfig();

        assertNotEq(initialUpgradeAuthority, address(this));
        assertNotEq(initialUpgradeAuthority, address(deployer));
        assertNotEq(initialUpgradeAuthority, broadcaster);
        assertNotEq(initialUpgradeAuthority, address(collateralToken));
        assertNotEq(initialUpgradeAuthority, address(debtToken));
        assertNotEq(initialUpgradeAuthority, address(priceFeed));

        (CollateralVault vault, LendingPool implementation, ERC1967Proxy proxy, LendingPool pool) =
            _deployAsBroadcaster(config);

        assertNotEq(initialUpgradeAuthority, address(vault));
        assertNotEq(initialUpgradeAuthority, address(implementation));
        assertNotEq(initialUpgradeAuthority, address(proxy));
        assertEq(pool.upgradeAuthority(), initialUpgradeAuthority);
        assertEq(pool.pendingUpgradeAuthority(), address(0));

        _expectUnauthorizedProposal(pool, address(this));
        _expectUnauthorizedProposal(pool, address(deployer));
        _expectUnauthorizedProposal(pool, broadcaster);

        vm.prank(initialUpgradeAuthority);
        pool.proposeUpgradeAuthority(proposedUpgradeAuthority);

        assertEq(pool.upgradeAuthority(), initialUpgradeAuthority);
        assertEq(pool.pendingUpgradeAuthority(), proposedUpgradeAuthority);
    }

    function test_DeployedImplementationAndProxyCannotBeInitializedAgain() public {
        DeployLendingPoolV1.DeploymentConfig memory config = _validConfig();
        (CollateralVault vault, LendingPool implementation,, LendingPool pool) = _deployAsBroadcaster(config);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _initialize(implementation, config, address(vault));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _initialize(pool, config, address(vault));

        _assertInitializedConfiguration(pool, vault, config, block.timestamp);
        assertEq(pool.upgradeAuthority(), initialUpgradeAuthority);
        assertEq(pool.pendingUpgradeAuthority(), address(0));
        assertEq(pool.totalCollateralShares(), 0);
        assertEq(pool.totalLiquidity(), 0);
        assertEq(pool.totalScaledDebt(), 0);
    }

    function test_InvalidRequiredAddressConfigurationRevertsBeforeAnyDeployment() public {
        DeployLendingPoolV1.DeploymentConfig memory config = _validConfig();

        config.collateralAsset = address(0);
        _expectInvalidConfig(
            config, abi.encodeWithSelector(DeployLendingPoolV1.InvalidCollateralAsset.selector, address(0))
        );

        config = _validConfig();
        config.debtAsset = address(0);
        _expectInvalidConfig(config, abi.encodeWithSelector(DeployLendingPoolV1.InvalidDebtAsset.selector, address(0)));

        config = _validConfig();
        config.priceFeed = address(0);
        _expectInvalidConfig(config, abi.encodeWithSelector(DeployLendingPoolV1.InvalidPriceFeed.selector, address(0)));

        config = _validConfig();
        config.initialUpgradeAuthority = address(0);
        _expectInvalidConfig(
            config, abi.encodeWithSelector(DeployLendingPoolV1.InvalidInitialUpgradeAuthority.selector, address(0))
        );
    }

    function test_InvalidEconomicConfigurationRevertsBeforeAnyDeployment() public {
        DeployLendingPoolV1.DeploymentConfig memory config = _validConfig();

        config.maxPriceStaleness = 0;
        _expectInvalidConfig(
            config, abi.encodeWithSelector(DeployLendingPoolV1.InvalidMaxPriceStaleness.selector, uint256(0))
        );

        config = _validConfig();
        config.ltvBps = 0;
        _expectInvalidRiskConfig(config);

        config = _validConfig();
        config.liquidationThresholdBps = 0;
        _expectInvalidRiskConfig(config);

        config = _validConfig();
        config.liquidationBonusBps = 0;
        _expectInvalidRiskConfig(config);

        config = _validConfig();
        config.ltvBps = config.liquidationThresholdBps;
        _expectInvalidRiskConfig(config);

        config = _validConfig();
        config.liquidationThresholdBps = 10_001;
        _expectInvalidRiskConfig(config);

        config = _validConfig();
        config.liquidationBonusBps = 10_001;
        _expectInvalidRiskConfig(config);

        config = _validConfig();
        config.baseBorrowRate = 0.8e18;
        config.borrowRateSlope = 0.3e18;
        _expectInvalidInterestConfig(config);

        config = _validConfig();
        config.baseBorrowRate = type(uint256).max;
        config.borrowRateSlope = 1;
        _expectInvalidInterestConfig(config);
    }

    function _validConfig() internal view returns (DeployLendingPoolV1.DeploymentConfig memory) {
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
            initialUpgradeAuthority: initialUpgradeAuthority
        });
    }

    function _deployAsBroadcaster(DeployLendingPoolV1.DeploymentConfig memory config)
        internal
        returns (CollateralVault vault, LendingPool implementation, ERC1967Proxy proxy, LendingPool pool)
    {
        vm.prank(broadcaster);
        return deployer.deploy(config);
    }

    function _assertInitializedConfiguration(
        LendingPool pool,
        CollateralVault vault,
        DeployLendingPoolV1.DeploymentConfig memory config,
        uint256 initializationTimestamp
    ) internal view {
        assertEq(address(pool.priceFeed()), config.priceFeed);
        assertEq(address(pool.vault()), address(vault));
        assertEq(address(pool.debtAsset()), config.debtAsset);
        assertEq(address(pool.collateralAsset()), config.collateralAsset);
        assertEq(pool.maxPriceStaleness(), config.maxPriceStaleness);
        assertEq(pool.ltvBps(), config.ltvBps);
        assertEq(pool.liquidationThresholdBps(), config.liquidationThresholdBps);
        assertEq(pool.liquidationBonusBps(), config.liquidationBonusBps);
        assertEq(pool.baseBorrowRate(), config.baseBorrowRate);
        assertEq(pool.borrowRateSlope(), config.borrowRateSlope);
        assertEq(pool.borrowIndex(), WAD);
        assertEq(pool.lastBorrowIndexUpdate(), initializationTimestamp);
        assertEq(pool.upgradeAuthority(), config.initialUpgradeAuthority);
        assertEq(pool.pendingUpgradeAuthority(), address(0));
    }

    function _assertInitializationData(DeployLendingPoolV1.DeploymentConfig memory config, address vault)
        internal
        view
    {
        bytes memory initializationData = deployer.encodeInitializationData(config, vault);
        assertGt(initializationData.length, 0);
        assertEq(
            initializationData,
            abi.encodeCall(
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
            )
        );
    }

    function _expectUnauthorizedProposal(LendingPool pool, address caller) internal {
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.UnauthorizedUpgradeAuthority.selector, caller));
        pool.proposeUpgradeAuthority(proposedUpgradeAuthority);
    }

    function _initialize(LendingPool target, DeployLendingPoolV1.DeploymentConfig memory config, address vault)
        internal
    {
        target.initialize(
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
        );
    }

    function _expectInvalidConfig(DeployLendingPoolV1.DeploymentConfig memory config, bytes memory expectedRevert)
        internal
    {
        uint64 nonceBefore = vm.getNonce(address(deployer));

        vm.expectRevert(expectedRevert);
        deployer.deploy(config);

        assertEq(vm.getNonce(address(deployer)), nonceBefore);
    }

    function _expectInvalidRiskConfig(DeployLendingPoolV1.DeploymentConfig memory config) internal {
        _expectInvalidConfig(
            config,
            abi.encodeWithSelector(
                DeployLendingPoolV1.InvalidRiskParameters.selector,
                config.ltvBps,
                config.liquidationThresholdBps,
                config.liquidationBonusBps
            )
        );
    }

    function _expectInvalidInterestConfig(DeployLendingPoolV1.DeploymentConfig memory config) internal {
        _expectInvalidConfig(
            config,
            abi.encodeWithSelector(
                DeployLendingPoolV1.InvalidInterestRateModel.selector, config.baseBorrowRate, config.borrowRateSlope
            )
        );
    }

    function _storedAddress(address target, bytes32 slot) internal view returns (address) {
        return address(uint160(uint256(vm.load(target, slot))));
    }
}
