# Lending Protocol Specification

## 1. Scope and version status

The protocol supports overcollateralized borrowing from a single debt-asset liquidity pool. Users deposit ERC-4626-backed collateral, borrow while within the configured LTV, repay indexed debt, and withdraw only while solvent. Third parties may liquidate positions below the liquidation threshold.

Three version contexts must remain distinct:

- **Historical public V1:** the canonical Sepolia ERC-1967 proxy is live and still delegates to its recorded V1 implementation. Its representative public flow is historical V1 evidence.
- **Completed local V1.2 work:** the repository implements and tests V1.2 interest accounting, V1/V1.1 migration, frozen storage compatibility, and Safe preparation and verification tooling.
- **Future public V1.2 action:** no public V1.1 or V1.2 upgrade has occurred. Deploying a V1.2 implementation and executing the atomic migration through Safe require separate explicit authorization.

This specification describes tested behavior and defined boundaries. It is not an audit, formal-verification result, or production-readiness claim.

## 2. Actors and authority

- **Liquidity provider:** deposits the debt asset and holds a nominal `liquidityBalanceOf` claim.
- **Borrower:** deposits collateral and borrows the debt asset.
- **Liquidator:** repays unhealthy debt and receives collateral.
- **Oracle:** supplies collateral/debt pricing through a Chainlink-compatible interface.
- **Deployment operator:** supplies dependencies and fixed economic configuration during one-time initialization.
- **Active upgrade authority:** may authorize UUPS upgrades and nominate a replacement authority.
- **Pending upgrade authority:** may accept a nomination but cannot upgrade before acceptance.

The active authority proposes a nonzero pending address; only that address may accept. Acceptance replaces the active authority and clears the pending value. There is no authority-renunciation or zero-address transfer path. The public proxy's active authority is the recorded 2-of-2 Safe.

## 3. Canonical state and custody

The ERC-1967 proxy is the canonical `LendingPool`, protocol-state address, direct debt-asset custodian, and owner of the pool's ERC-4626 vault shares. Implementation contracts are delegatecall code targets and are not protocol custody addresses. `CollateralVault` is separately deployed and non-upgradeable; it holds collateral assets while the proxy owns shares and records user share claims.

Core state includes fixed risk and rate configuration, a global borrow index and timestamp, aggregate scaled debt, aggregate liquidity and collateral shares, and per-account scaled-debt, liquidity, and collateral-share mappings. V1.2 appends no mutable protocol storage: compiler-layout and golden-layout tests keep the same 18 linear entries and mapping seeds at slots 0–17. The existing OpenZeppelin Initializable namespace changes from version 1 to version 2 during migration; this is activation metadata, not newly appended protocol storage.

## 4. Position rules

```text
healthFactor = collateralValue * liquidationThreshold / currentDebt

healthFactor >= 1e18  healthy
healthFactor <  1e18  liquidatable
```

Debt-free positions return `type(uint256).max`. A borrow must fit both the account's LTV limit and available liquidity. An indebted collateral withdrawal must leave a health factor of at least `1e18` after accounting for the ceiling-rounded vault share cost.

Collateral deposits transfer assets through the proxy into the vault and revert atomically if a nonzero deposit produces zero shares. Liquidation computes the desired seizure with the configured bonus, caps it to available collateral, and reduces repayment to the supportable amount when necessary. The vault share debit uses ceiling-rounded `previewWithdraw`; `redeem` determines the actual asset output reported in the event. Any uncovered scaled debt remains visible.

## 5. Rate and utilization model

The annual rate input is WAD-scaled:

```text
storedDebt = floor(totalScaledDebt * storedBorrowIndex / 1e18)

utilization = 0                                      if totalLiquidity = 0
utilization = 1e18                                   if storedDebt >= totalLiquidity
utilization = floor(storedDebt * 1e18 / liquidity)  otherwise

annualRate = baseBorrowRate
           + floor(utilization * borrowRateSlope / 1e18)
```

The model is linear and has no kink. Valid configuration and migration require `baseBorrowRate <= 1e18` and `borrowRateSlope <= 1e18 - baseBorrowRate`, so the supported annual-rate domain is 0% through 100% WAD inclusive.

## 6. Checkpoint ordering

The borrow index must be checkpointed before every mutation that changes utilization and therefore changes the future borrow rate. This includes liquidity deposits and withdrawals as well as debt-changing borrow, repay, and liquidation operations.

The required ordering is:

```text
settle elapsed time using the pre-mutation rate
  -> store the resulting index and current timestamp
  -> mutate liquidity or debt state
  -> apply the new rate only to future elapsed time
```

Checks or external calls that later revert also roll back the checkpoint. Collateral deposits, view calls, and the passage of time alone do not persist a checkpoint.

The historical deployed V1 bytecode does not checkpoint liquidity mutations. A liquidity change can therefore cause V1's next debt checkpoint to apply the then-current utilization to the still-open preceding interval. The source-level checkpoint correction, inherited by the V1.2 candidate, closes that boundary. A deposit that lowers utilization slows future growth only; it never reduces the already accrued index or nominal borrower debt. A withdrawal that raises utilization likewise affects only future elapsed time after the boundary.

## 7. V1.2 interest accounting

V1.2 accepts a WAD nominal annual rate and stores the cumulative borrow index in WAD. `BorrowIndexMath` converts the per-second base to RAY (`1e27`) and performs floor-rounded exponentiation by squaring, providing RAY intermediate precision for once-per-second discrete compounding:

```text
perSecondBaseRay = 1e27 + floor(annualRateWad * 1e9 / 365 days)
growthRay        = floor-rounded powRay(perSecondBaseRay, elapsedSeconds)
newIndexWad      = floor(indexWad * growthRay / 1e27)
```

This is discrete per-second compounding, not continuous or per-block compounding. Every library division rounds down. Repeated checkpointing can differ slightly from one uninterrupted call because each checkpoint quantizes, and tests bound that partitioning error.

The numerical domain is deliberately bounded:

- the annual rate is at most `1e18` (100%);
- one positive-rate accrual call covers at most `100 * 365 days`;
- zero elapsed time and zero rate are identity cases, and a debt-free interval leaves the index unchanged before calling the accrual library;
- the active index must be at least `1e18`; and
- `ceil(index / 1e18)` must not exceed `1_000_000`, so the largest supported index is `1_000_000 * 1e18` (`1e24`).

The debt quantum is `ceil(index / 1e18)`. It bounds the raw-unit mismatch introduced by scaled-debt conversions. V1.2 does not claim unlimited values or elapsed intervals; unsupported index growth, interval length, rates, and final quotients revert.

V1.2 uses full-width `Math.mulDiv` for index growth, nominal/scaled conversion, utilization, and variable-rate multiplication so an overflowing intermediate product can still succeed when the quotient fits `uint256`. The legacy interval inside migration deliberately retains the historical formula and operation order.

Debt conversion directions are explicit:

- displayed account and aggregate debt: `floor(scaled * index / 1e18)`;
- new borrow: `ceil(amount * 1e18 / index)`, followed by floor-normalized LTV and aggregate-liquidity admission checks;
- partial repayment and partial liquidation repayment: `floor(payment * 1e18 / index)` scaled units burned;
- full repayment, or liquidation of the full displayed debt, clears the account's entire scaled balance.

A partial payment that would burn zero scaled units reverts with `ZeroScaledAmount`; borrow conversion also rejects a zero scaled result. These checks prevent token movement with no representable accounting change.

Scaled debt is a share-like accounting unit, not nominal debt. Existing scaled balances remain constant while time-driven index growth raises nominal debt. For the same nominal amount, a borrow entered at a higher index mints fewer scaled units; a repayment at a higher index may burn fewer scaled units. Thus scaled amounts can be numerically smaller as the index grows while `floor(scaled * index / 1e18)` remains the correct nominal debt under the stated rounding rules.

V1.2 enforces an 18-decimal debt asset during initial V1.2 deployment and migration. That check does not by itself prove exact-transfer, non-rebasing behavior or oracle-unit compatibility; those remain deployment-review requirements.

## 8. Atomic V1/V1.1-to-V1.2 migration

The accepted migration is a call by the active authority to the canonical proxy:

```text
upgradeToAndCall(newV1_2Implementation, abi.encodeCall(migrateToV1_2, ()))
```

UUPS validates proxy context and the candidate's ERC-1822 UUID, then the delegated `migrateToV1_2()` executes in the same transaction. The migration is a `reinitializer(2)`, requires proxy execution, and independently requires `msg.sender` to remain the active upgrade authority.

Migration performs these state transitions:

1. read the stored legacy index and elapsed time since the last checkpoint;
2. require the legacy index to be at least WAD;
3. if elapsed time and scaled debt are nonzero, settle the complete open interval with the exact historical V1/V1.1 second-order formula and historical operation order;
4. store the settled index and activation timestamp;
5. validate the settled index/debt-quantum bound, 18-decimal debt asset, and annual-rate domain; and
6. complete initializer version 2, emit `V1_2Activated`, and use RAY-based accrual only for time after activation.

The existing scaled-debt values are not rewritten. Their nominal value at the boundary is preserved by settling and retaining the common index domain before future V1.2 accrual begins. Configuration, user mapping values, aggregate liquidity, aggregate scaled debt, collateral shares, authorities, proxy address, token custody, vault custody, approvals, and the frozen protocol layout remain unchanged; only the index, checkpoint timestamp, implementation slot, and initialization version change as specified.

Accounting calls in a V1.2 implementation require initializer version 2 and fail with `V1_2AccountingInactive` before activation. Zero or sub-WAD indexes and unsupported accounting domains revert. If any migration check fails during `upgradeToAndCall`, EVM rollback restores both the implementation slot and all state. A plain implementation replacement with empty or different migration calldata is not an accepted path even though tests show that a separately authorized later migration can recover an inactive install in controlled conditions.

## 9. Oracle and token assumptions

Price reads require a positive answer, a nonzero timestamp not in the future, acceptable staleness, and `answeredInRound >= roundId`. Feed decimals from 0 through 18 are normalized to WAD; unsupported decimals, normalization overflow, and a zero normalized result revert.

Both assets must be standard, exact-transfer, non-rebasing ERC-20s whose raw units and feed quotation are compatible. The pool does not reconcile nominal accounting against token balance deltas. Fee-on-transfer, reflective, rebasing, callback-capable, or otherwise adversarial assets can violate assumptions. `SafeERC20` does not provide a reentrancy guard.

## 10. Tested properties and limitations

Unit, fuzz, invariant, integration, storage-layout, migration, and script tests cover the accounting domains and boundaries above. Stateful tests run through real proxies and check aggregate identities, current-index monotonicity, custody coverage, healthy-position liquidation rejection, and campaign reachability. Script tests validate candidate identity, canonical payload construction, state evidence, tracked mapping leaves, atomic rollback, and read-only post-upgrade reconciliation.

Important limitations remain:

- lender yield distribution and a supply index are not implemented;
- collateral-capped liquidation may leave residual debt without reserves or socialization;
- partial liquidation is not required to improve the resulting health factor;
- the pool has no pause control, general reentrancy guard, close factor, economic setters, or timelock;
- mappings cannot be enumerated on-chain, so operational verification depends on an operator-derived tracked-account set plus authenticated bytecode and reviewed migration logic; and
- tests and internal development review do not constitute an audit, formal verification, or proof over arbitrary integrations.
