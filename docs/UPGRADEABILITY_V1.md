# LendingPool UUPS Upgradeability and V1.2 Migration

## 1. Status and scope

This document defines the repository's UUPS/ERC-1967 architecture, frozen V1 storage contract, and V1/V1.1-to-V1.2 migration.

The public Sepolia system is a completed historical V1 deployment. Its canonical ERC-1967 proxy remains at `0x4Ba81845c2E130013EF2Be36e220cA1166E70873` and still points to V1 implementation `0x4f5c7dC968602b54519F515576FeC936405CB940`. The public representative flow was executed against V1. No public V1.1 or V1.2 upgrade has occurred.

V1.2 is implemented, tested, migration-reviewed within this development workflow, and supported by Safe-controlled preparation and read-only verification tooling. It is a local upgrade candidate, not a publicly installed version. Deployment of a candidate implementation and Safe execution remain future explicitly authorized operations. This repository does not claim an audit, formal verification, or production readiness.

## 2. Proxy, implementation, and custody roles

`LendingPool` inherits OpenZeppelin `Initializable` and `UUPSUpgradeable` and executes through an `ERC1967Proxy`. The implementation constructor calls `_disableInitializers()`. A new proxy is initialized atomically from nonempty constructor calldata containing nine dependency/economic inputs and the explicitly chosen initial upgrade authority.

In delegated execution, the proxy is `address(this)`. It is the canonical pool, owns all LendingPool state, directly holds debt-asset balances, owns the vault shares, and holds pool-to-vault approvals. The implementation is code only. `CollateralVault` is a separately deployed non-upgradeable ERC-4626 contract and remains the authoritative holder of collateral assets.

The ERC-1967 implementation slot is:

```text
0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
```

OpenZeppelin's initialization state uses its ERC-7201 namespace at:

```text
0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00
```

V1.2 overrides `_initializableStorageSlot()` with that established location, so migration advances the same proxy initialization record from version 1 to 2.

## 3. Upgrade authority

Upgrade authority is stored outside the linear protocol layout in this ERC-7201 namespace:

```text
lending.protocol.storage.LendingPoolUpgradeAuthority
0x8000ce11f38414f298b74975bfaea500fcdbebb431834e96f66ac2883c9bb800
```

The namespace stores `activeAuthority` followed by `pendingAuthority`. Only the active authority may propose a nonzero pending authority or pass `_authorizeUpgrade`. Only the current pending authority may accept; acceptance replaces the active authority and clears the pending value. There is no renounce function or zero-address transfer path.

For the public deployment, the active authority is the recorded 2-of-2 Safe and the pending authority is zero. The deployer has no implicit upgrade permission. Foundry tooling may deploy a candidate and prepare calldata, but it never receives or impersonates Safe authority and does not execute the proxy upgrade.

## 4. Frozen protocol storage

V1, V1.1, and V1.2 have the same compiler-reported mutable protocol layout. V1.2 declares no appended mutable storage.

| Slot | Offset | Bytes | Field | Type |
| ---: | ---: | ---: | --- | --- |
| 0 | 0 | 32 | `ltvBps` | `uint256` |
| 1 | 0 | 32 | `liquidationThresholdBps` | `uint256` |
| 2 | 0 | 32 | `liquidationBonusBps` | `uint256` |
| 3 | 0 | 20 | `vault` | `CollateralVault` |
| 4 | 0 | 20 | `priceFeed` | `IPriceFeed` |
| 5 | 0 | 20 | `debtAsset` | `IERC20` |
| 6 | 0 | 20 | `collateralAsset` | `IERC20` |
| 7 | 0 | 32 | `maxPriceStaleness` | `uint256` |
| 8 | 0 | 32 | `borrowIndex` | `uint256` |
| 9 | 0 | 32 | `lastBorrowIndexUpdate` | `uint256` |
| 10 | 0 | 32 | `totalCollateralShares` | `uint256` |
| 11 | 0 | 32 | `totalLiquidity` | `uint256` |
| 12 | 0 | 32 | `baseBorrowRate` | `uint256` |
| 13 | 0 | 32 | `borrowRateSlope` | `uint256` |
| 14 | 0 | 32 | `totalScaledDebt` | `uint256` |
| 15 | 0 | 32 | `scaledDebtOf` seed | `mapping(address => uint256)` |
| 16 | 0 | 32 | `collateralSharesOf` seed | `mapping(address => uint256)` |
| 17 | 0 | 32 | `liquidityBalanceOf` seed | `mapping(address => uint256)` |

Slots 0–17 and their mapping key/value types are immutable compatibility commitments. Implementations must not reorder, remove, repurpose, or insert fields within this prefix, introduce inherited linear storage ahead of it, or assume a dependency upgrade is layout-compatible without inspecting its source and compiler layout.

Golden-layout tests compare V1, V1.1, and V1.2 artifacts against all 18 entries and confirm representative nonzero mapping leaves at the frozen seeds. They also preserve historical selectors; V1.2 adds only `migrateToV1_2()` beyond the V1.1 interface.

## 5. Interest-accounting evolution

Historical V1 uses WAD rate and index arithmetic with a second-order approximation. It checkpoints debt-changing operations but its deployed bytecode does not checkpoint liquidity deposits or withdrawals. The current source checkpoint correction persists the pre-mutation interval before every debt or liquidity mutation:

```text
settle at old utilization -> store index and timestamp -> mutate -> use new rate prospectively
```

That correction is inherited by V1.1 and V1.2. Lower utilization slows future index growth; it cannot decrease an accrued index or borrower debt.

V1.2 replaces prospective interest growth with once-per-second compounding. The nominal annual rate remains WAD, the stored index remains WAD, and `BorrowIndexMath` uses RAY precision internally for the per-second base and exponentiation. It uses full-width `Math.mulDiv` and explicit rounding: ceil for scaled debt minted by a borrow; floor for displayed debt, utilization, variable rate, and scaled debt burned by a partial repayment or liquidation. A zero scaled change reverts, while full repayment clears all of the account's scaled debt.

Supported V1.2 accounting is bounded to combined annual rates at or below 100%, positive-rate single-call intervals at or below 100 years, an index at least WAD, and a debt quantum `ceil(index / WAD)` at most `1_000_000` (therefore index at most `1e24`). The debt asset must report exactly 18 decimals. These bounds avoid an unsupported numerical regime; they do not assert unlimited numerical support.

Existing scaled balances are share-like units. Index growth increases their nominal value without mutating the balances. Equal nominal borrows at higher indexes require fewer scaled units, so smaller scaled numbers do not imply reduced nominal debt.

## 6. Atomic V1/V1.1-to-V1.2 migration

The only accepted upgrade payload is the canonical proxy call:

```solidity
upgradeToAndCall(
    newImplementation,
    abi.encodeCall(LendingPoolV1_2.migrateToV1_2, ())
)
```

The same active authority is checked by UUPS authorization and by `migrateToV1_2()`. The inner call is `onlyProxy` and `reinitializer(2)`. UUPS also requires the candidate to expose the expected ERC-1822 UUID.

During migration, accounting is inactive until the reinitializer finishes. The implementation:

1. reads the pre-migration `borrowIndex` and elapsed time;
2. rejects an index below WAD;
3. settles the entire open historical interval with the exact legacy V1/V1.1 formula and checked-arithmetic operation order, using the pre-migration liquidity, scaled debt, and rate configuration;
4. stores the settled index and the current block timestamp;
5. validates the V1.2 index/quantum, debt-decimal, and interest-rate domains; and
6. activates initializer version 2 and emits `V1_2Activated`.

This settlement normalizes the transition at one accounting boundary; it does not rewrite per-user or aggregate scaled debt. The V1.2 formula applies only after activation. Configuration, aggregate totals other than the specified index/timestamp transition, mapping values, authority state, custody, proxy address, vault address, and frozen layout are preserved.

If legacy arithmetic or any V1.2 validation fails, the whole `upgradeToAndCall` reverts, including the ERC-1967 implementation-slot change and initializer-version write. Zero/sub-WAD indexes, unsupported debt decimals, invalid rates, and excessive debt quantum are tested rollback cases.

A plain implementation replacement with empty calldata is not accepted. It can leave the V1.2 implementation installed at initializer version 1, where accounting-dependent views and mutations fail with `V1_2AccountingInactive`. Tests cover an authorized recovery migration, but operators must not use that recovery case as the planned path.

## 7. State-preservation requirements

Before and after an accepted migration, verification must establish:

- the same canonical proxy, active and pending authority, dependencies, risk configuration, and rate configuration;
- the same `totalCollateralShares`, `totalLiquidity`, `totalScaledDebt`, and selected mapping leaves;
- the exact legacy-settled boundary index and activation timestamp;
- initializer version 2, V1.2 version reporting, and the candidate address and runtime code hash in the implementation slot;
- the same proxy debt balance, direct proxy collateral balance, proxy vault shares, vault total assets, vault total supply, and vault collateral balance; and
- prospective current rate and current index matching an independent V1.2 calculation.

Raw mapping seeds cannot enumerate mapping contents. The operator supplies a canonical strictly sorted account list derived from authenticated deployment and interaction evidence. When that list is declared complete, the preparation and verifier require its scaled debt, collateral shares, and liquidity balances to sum to the aggregate totals. When it is incomplete, continuity is proven only for the supplied leaves; authenticated candidate bytecode and separately reviewed migration logic remain part of the assurance boundary.

Implementation balances are not authoritative custody. Construction-time checks ensure candidate deployment itself creates no balance delta at the predicted candidate address. Later permissionless transfers can add token or vault-share dust to either implementation; post-verification reports exact deltas but does not let implementation dust determine the core verdict. Proxy and vault custody are authoritative and any mismatch fails verification.

## 8. Safe preparation and verification boundary

`UpgradeLendingPoolV1_2.s.sol` directly constructs the typed V1.2 implementation, authenticates its runtime `extcodehash`, UUID, version, and locked initializer state, snapshots pre-upgrade evidence, and emits the exact proxy target, zero value, and canonical migration calldata. Its broadcast boundary ends after implementation deployment. It does not submit a Safe proposal or execute an upgrade.

The preparation output includes a pre-upgrade state hash, payload fingerprint, tracked-account commitment, and preparation-attestation digest. The operator must preserve the digest independently and supply it to `VerifyLendingPoolV1_2Upgrade.s.sol` after Safe execution. The verifier recomputes it over the preparation identities, evidence commitments, and payload.

The digest detects substitution only when the original independently preserved digest remains trusted. It is not a signature, Safe transaction hash, deployment receipt, registry record, or on-chain attestation. A local verifier cannot detect replacement of both the evidence bundle and its externally supplied trust root. Safe owner set, threshold, nonce, EIP-712 transaction hash, signatures, approvals, receipt, and logs remain an external review and evidence responsibility.

Preparation evidence is not an on-chain transaction guard. A fresh preflight and controlled state window are required immediately before future Safe execution. See [SAFE_UPGRADE_RUNBOOK.md](SAFE_UPGRADE_RUNBOOK.md).

## 9. Failure and rollback rules

- Any preparation mismatch fails before a canonical payload is accepted.
- Any state change between snapshot and execution invalidates the stale evidence; discard the proposal, rerun preparation, and restart review.
- Any migration failure reverts the implementation replacement and migration writes atomically.
- Any post-verification mismatch means the upgrade must not be reported as verified.
- Do not automatically execute a corrective upgrade. Preserve evidence, diagnose the mismatch, and treat any response as a separately reviewed Safe operation.

## 10. Future upgrade rules

Every future implementation must retain slots 0–17 and all established namespaces, provide a version-specific storage and migration review, authenticate code and UUPS compatibility, and use explicitly reviewed `upgradeToAndCall` data. Reinitializers require a unique increasing version and must be executed atomically when their state transition is required.

New economic features—such as lender yield, reserves, close factors, decimal adapters, parameter governance, or bad-debt resolution—require separate specifications and tests. They are not implied by V1.2.
