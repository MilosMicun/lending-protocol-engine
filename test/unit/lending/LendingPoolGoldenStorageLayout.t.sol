// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {LendingPoolProxyFixture} from "../../helpers/LendingPoolProxyFixture.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";

import {LendingPool} from "../../../src/core/lending/LendingPool.sol";
import {CollateralVault} from "../../../src/core/vault/CollateralVault.sol";

contract LendingPoolGoldenStorageLayoutTest is Test, LendingPoolProxyFixture {
    struct FrozenEntry {
        string label;
        string typeLabel;
        string encoding;
        string keyTypeLabel;
        string valueTypeLabel;
        uint256 slot;
        uint256 offset;
        uint256 size;
    }

    struct CompilerStorageEntry {
        uint256 astId;
        string contractName;
        string label;
        uint256 offset;
        string slot;
        string typeId;
    }

    string internal constant V1_ARTIFACT = "out/LendingPool.sol/LendingPool.json";
    string internal constant V1_1_ARTIFACT = "out/LendingPoolV1_1.sol/LendingPoolV1_1.json";

    uint256 internal constant FROZEN_ENTRY_COUNT = 18;
    uint256 internal constant SCALED_DEBT_OF_SEED = 15;
    uint256 internal constant COLLATERAL_SHARES_OF_SEED = 16;
    uint256 internal constant LIQUIDITY_BALANCE_OF_SEED = 17;

    address internal constant BORROWER = 0x1111111111111111111111111111111111111111;
    address internal constant LIQUIDITY_PROVIDER = 0x2222222222222222222222222222222222222222;

    uint256 internal constant EXPECTED_SCALED_DEBT = 250 ether;
    uint256 internal constant EXPECTED_COLLATERAL_SHARES = 500 ether;
    uint256 internal constant EXPECTED_LIQUIDITY_BALANCE = 1_000 ether;

    function test_V1CompilerLayoutMatchesFrozenOracle() public view {
        _assertCompilerLayout(V1_ARTIFACT, "LendingPool V1");
    }

    function test_V1_1CompilerLayoutMatchesFrozenOracleAndAddsNoStorage() public view {
        _assertCompilerLayout(V1_1_ARTIFACT, "LendingPool V1.1");
    }

    function test_FrozenMappingSeedsLocateRepresentativeNonzeroLeaves() public {
        MockERC20 collateralToken = new MockERC20("Collateral Token", "COL");
        MockERC20 debtToken = new MockERC20("Debt Token", "DEBT");
        CollateralVault vault = new CollateralVault("Collateral Vault Share", "CVS", collateralToken);
        MockV3Aggregator priceFeed = new MockV3Aggregator(8, 1e8, block.timestamp);

        (LendingPool pool,) = _deployLendingPoolProxy(
            LendingPoolProxyConfig({
                priceFeed: address(priceFeed),
                vault: address(vault),
                debtAsset: address(debtToken),
                maxPriceStaleness: 1 days,
                ltvBps: 7_000,
                liquidationThresholdBps: 8_000,
                liquidationBonusBps: 500,
                baseBorrowRate: 0.05e18,
                borrowRateSlope: 0.2e18,
                initialUpgradeAuthority: address(this)
            })
        );

        debtToken.mint(LIQUIDITY_PROVIDER, EXPECTED_LIQUIDITY_BALANCE);
        vm.startPrank(LIQUIDITY_PROVIDER);
        debtToken.approve(address(pool), EXPECTED_LIQUIDITY_BALANCE);
        pool.depositLiquidity(EXPECTED_LIQUIDITY_BALANCE);
        vm.stopPrank();

        collateralToken.mint(BORROWER, EXPECTED_COLLATERAL_SHARES);
        vm.startPrank(BORROWER);
        collateralToken.approve(address(pool), EXPECTED_COLLATERAL_SHARES);
        pool.depositCollateral(EXPECTED_COLLATERAL_SHARES);
        pool.borrow(EXPECTED_SCALED_DEBT);
        vm.stopPrank();

        bytes32 scaledDebtLeaf = keccak256(abi.encode(BORROWER, SCALED_DEBT_OF_SEED));
        bytes32 collateralSharesLeaf = keccak256(abi.encode(BORROWER, COLLATERAL_SHARES_OF_SEED));
        bytes32 liquidityBalanceLeaf = keccak256(abi.encode(LIQUIDITY_PROVIDER, LIQUIDITY_BALANCE_OF_SEED));

        assertEq(uint256(vm.load(address(pool), scaledDebtLeaf)), EXPECTED_SCALED_DEBT, "scaledDebtOf leaf");
        assertEq(
            uint256(vm.load(address(pool), collateralSharesLeaf)), EXPECTED_COLLATERAL_SHARES, "collateralSharesOf leaf"
        );
        assertEq(
            uint256(vm.load(address(pool), liquidityBalanceLeaf)), EXPECTED_LIQUIDITY_BALANCE, "liquidityBalanceOf leaf"
        );

        assertGt(uint256(vm.load(address(pool), scaledDebtLeaf)), 0, "scaledDebtOf leaf must be nonzero");
        assertGt(uint256(vm.load(address(pool), collateralSharesLeaf)), 0, "collateralSharesOf leaf must be nonzero");
        assertGt(uint256(vm.load(address(pool), liquidityBalanceLeaf)), 0, "liquidityBalanceOf leaf must be nonzero");
    }

    function _assertCompilerLayout(string memory artifactPath, string memory implementationName) internal view {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory artifact = vm.readFile(string.concat(vm.projectRoot(), "/", artifactPath));
        CompilerStorageEntry[] memory entries =
            abi.decode(vm.parseJson(artifact, ".storageLayout.storage"), (CompilerStorageEntry[]));

        assertEq(entries.length, FROZEN_ENTRY_COUNT, string.concat(implementationName, ": mutable entry count"));

        for (uint256 index; index < FROZEN_ENTRY_COUNT; ++index) {
            FrozenEntry memory expected = _frozenEntry(index);
            CompilerStorageEntry memory actual = entries[index];
            string memory typePath = string.concat(".storageLayout.types['", actual.typeId, "']");
            string memory context =
                string.concat(implementationName, ": entry ", vm.toString(index), " ", expected.label);

            assertEq(actual.label, expected.label, string.concat(context, ": label"));
            assertEq(actual.slot, vm.toString(expected.slot), string.concat(context, ": slot"));
            assertEq(actual.offset, expected.offset, string.concat(context, ": offset"));
            assertEq(
                vm.parseJsonString(artifact, string.concat(typePath, ".label")),
                expected.typeLabel,
                string.concat(context, ": type")
            );
            assertEq(
                vm.parseJsonString(artifact, string.concat(typePath, ".encoding")),
                expected.encoding,
                string.concat(context, ": encoding")
            );
            assertEq(
                vm.parseJsonUint(artifact, string.concat(typePath, ".numberOfBytes")),
                expected.size,
                string.concat(context, ": byte size")
            );

            if (bytes(expected.keyTypeLabel).length != 0) {
                string memory keyTypeId = vm.parseJsonString(artifact, string.concat(typePath, ".key"));
                string memory valueTypeId = vm.parseJsonString(artifact, string.concat(typePath, ".value"));

                assertEq(_typeLabel(artifact, keyTypeId), expected.keyTypeLabel, string.concat(context, ": key type"));
                assertEq(
                    _typeLabel(artifact, valueTypeId), expected.valueTypeLabel, string.concat(context, ": value type")
                );
            }
        }
    }

    function _typeLabel(string memory artifact, string memory typeId) internal pure returns (string memory) {
        return vm.parseJsonString(artifact, string.concat(".storageLayout.types['", typeId, "'].label"));
    }

    function _frozenEntry(uint256 index) internal pure returns (FrozenEntry memory) {
        if (index == 0) return _inplace("ltvBps", "uint256", 0, 32);
        if (index == 1) return _inplace("liquidationThresholdBps", "uint256", 1, 32);
        if (index == 2) return _inplace("liquidationBonusBps", "uint256", 2, 32);
        if (index == 3) return _inplace("vault", "contract CollateralVault", 3, 20);
        if (index == 4) return _inplace("priceFeed", "contract IPriceFeed", 4, 20);
        if (index == 5) return _inplace("debtAsset", "contract IERC20", 5, 20);
        if (index == 6) return _inplace("collateralAsset", "contract IERC20", 6, 20);
        if (index == 7) return _inplace("maxPriceStaleness", "uint256", 7, 32);
        if (index == 8) return _inplace("borrowIndex", "uint256", 8, 32);
        if (index == 9) return _inplace("lastBorrowIndexUpdate", "uint256", 9, 32);
        if (index == 10) return _inplace("totalCollateralShares", "uint256", 10, 32);
        if (index == 11) return _inplace("totalLiquidity", "uint256", 11, 32);
        if (index == 12) return _inplace("baseBorrowRate", "uint256", 12, 32);
        if (index == 13) return _inplace("borrowRateSlope", "uint256", 13, 32);
        if (index == 14) return _inplace("totalScaledDebt", "uint256", 14, 32);
        if (index == 15) return _mapping("scaledDebtOf", 15);
        if (index == 16) return _mapping("collateralSharesOf", 16);
        if (index == 17) return _mapping("liquidityBalanceOf", 17);

        revert("frozen oracle index out of bounds");
    }

    function _inplace(string memory label, string memory typeLabel, uint256 slot, uint256 size)
        internal
        pure
        returns (FrozenEntry memory)
    {
        return FrozenEntry({
            label: label,
            typeLabel: typeLabel,
            encoding: "inplace",
            keyTypeLabel: "",
            valueTypeLabel: "",
            slot: slot,
            offset: 0,
            size: size
        });
    }

    function _mapping(string memory label, uint256 seed) internal pure returns (FrozenEntry memory) {
        return FrozenEntry({
            label: label,
            typeLabel: "mapping(address => uint256)",
            encoding: "mapping",
            keyTypeLabel: "address",
            valueTypeLabel: "uint256",
            slot: seed,
            offset: 0,
            size: 32
        });
    }
}
