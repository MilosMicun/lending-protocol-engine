# Lending Protocol Specification

## 1. System Goal

The protocol enables overcollateralized borrowing by allowing users to deposit collateral and take debt against it.

The system enforces solvency through overcollateralization and liquidation mechanisms, ensuring that unhealthy positions can be closed before they create bad debt.

The primary objective of the protocol is to prevent bad debt and maintain system solvency, even at the cost of user position loss through liquidation.

---

## 2. Actors

- **Lender** — provides liquidity by depositing assets into the protocol  
- **Borrower** — deposits collateral and takes debt  
- **Liquidator** — repays unhealthy debt and seizes collateral for profit  
- **Oracle** — provides asset prices used for risk calculations (passive infrastructure component)  
- **Admin** — sets protocol parameters (LTV, liquidation threshold, liquidation bonus, oracle address)  

---

## 3. State Model

- **NoPosition** — no collateral and no debt  
- **Collateralized** — collateral > 0 and debt = 0  
- **HealthyDebt** — collateral > 0 and debt > 0, position is safe  
- **AtRiskDebt** — position approaches liquidation threshold (monitoring state)  
- **Liquidatable** — position is below liquidation threshold  
- **BadDebt** — collateral is insufficient to fully cover outstanding debt even after liquidation  

---

## 4. State Transitions

- NoPosition → deposit → Collateralized  
- Collateralized → deposit → Collateralized  
- Collateralized → borrow → HealthyDebt  
- Collateralized → withdraw(all) → NoPosition  
- Collateralized → withdraw(partial) → Collateralized  

- HealthyDebt → borrow → HealthyDebt / AtRiskDebt  
- HealthyDebt → repay(partial) → HealthyDebt  
- HealthyDebt → repay(full) → Collateralized  
- HealthyDebt → collateral value down → AtRiskDebt  
- HealthyDebt → add collateral → HealthyDebt  

- AtRiskDebt → collateral value down → Liquidatable  
- AtRiskDebt → repay/add collateral/value up → HealthyDebt  
- AtRiskDebt → repay(full) → Collateralized  

- Liquidatable → liquidation → HealthyDebt / Collateralized / NoPosition / Liquidatable  
- Liquidatable → liquidation → BadDebt (if collateral insufficient)  
- Liquidatable → repay/add collateral/value up → HealthyDebt / AtRiskDebt  

### Constraints

- Borrow must revert if resulting health factor < 1  
- Withdraw must revert if resulting health factor < 1  
- Withdraw must revert if available liquidity is insufficient  

---

## 5. Implemented Invariant Suite

The stateful Foundry suite is configured for 64 runs at depth 128. Effective configuration has
`fail_on_revert = false`; a zero handler-revert count is validation output, not an additional invariant. The
handler operates through the real proxy and exposes liquidity deposit, collateral deposit, borrow, repay,
liquidity withdrawal, collateral withdrawal, liquidation, and time-warp actions. Three tracked users act as
borrowers, collateral depositors, repayers, and external liquidity providers; the handler contract acts as the
liquidator and can also provide internal liquidity while preparing a borrow.

The nine `invariant_*` functions assert:

1. available liquidity does not exceed total liquidity;
2. total scaled debt equals the sum of the tracked users' scaled debt;
3. total current debt approximately equals the sum of tracked user debt, with a three-unit absolute tolerance;
4. total collateral shares equal the sum of tracked user collateral shares;
5. total liquidity equals the handler's balance plus all tracked provider balances;
6. the computed current borrow index is at least the stored index, and the stored index is at least `1e18`;
7. a tracked user with zero scaled debt has zero current debt;
8. the pool debt-asset balance, plus one unit per successful handler borrow as rounding tolerance, covers
   available liquidity; and
9. attempting to liquidate a tracked debtor with health factor at least `1e18` reverts with
   `PositionNotLiquidatable`.

`afterInvariant()` separately requires campaign-level successful borrow and liquidation reachability, at least two
successful external liquidity deposits from at least two distinct user providers, and successful liquidity and
collateral withdrawals. It does not require every generated run to reach every action. Repay, direct collateral
deposit, and time warp are handler actions without explicit reachability assertions; repayment scenarios are
covered separately by unit and fuzz tests. Handler action assertions, reachability checks, and the nine invariant
functions are distinct forms of coverage and do not establish exhaustive state-space or security proof.

---

## 6. Failure Scenarios

- Oracle price is stale → incorrect risk assessment  
- Oracle price is wrong or manipulated → invalid borrowing or liquidation  
- Large price deviation → sudden mass liquidations  
- Liquidation does not sufficiently improve position → risk of bad debt  
- Accounting mismatch between totals and user balances  
- Insufficient protocol liquidity to fulfill borrow or withdraw  
- Liquidation incentive too low → no liquidators  
- Rapid collateral price collapse → system enters BadDebt state  

### Oracle Runtime Validation

Phase 1 supports price feeds with 0–18 decimals. Accepted prices must be positive, nonzero after WAD
normalization, non-future, and within the configured maximum-staleness window. Unsupported feed decimals and unsafe
normalization states revert. Compatible collateral/debt token-unit assumptions remain a separate documented
limitation and are not redesigned by this validation.

---

## 7. Accounting Model (Simplified One-Pool Model)

### User State

- collateralBalanceOf[user]  
- debtBalanceOf[user]  

### System State

- totalCollateral  
- totalDebt  
- availableLiquidity  

---

### Deposit

- collateralBalanceOf[user] += amount  
- totalCollateral += amount  
- availableLiquidity += amount  

LendingPool collateral deposits must revert atomically when the ERC-4626 vault returns zero shares. A reverted
zero-share deposit must not transfer value or change protocol collateral accounting. Direct use of the generic
CollateralVault remains outside this LendingPool-side guarantee.

---

### Borrow

- debtBalanceOf[user] += amount  
- totalDebt += amount  
- availableLiquidity -= amount  

---

### Repay

- actualRepay = min(amount, debtBalanceOf[user])  
- debtBalanceOf[user] -= actualRepay  
- totalDebt -= actualRepay  
- availableLiquidity += actualRepay  

---

### Withdraw

- collateralBalanceOf[user] -= amount  
- totalCollateral -= amount  
- availableLiquidity -= amount  

---

### Liquidation

- actualRepay = min(repayAmount, debtBalanceOf[user])  
- debtBalanceOf[user] -= actualRepay  
- totalDebt -= actualRepay  
- availableLiquidity += actualRepay  

- collateralBalanceOf[user] -= collateralToSeize  
- totalCollateral -= collateralToSeize  

- collateralToSeize is transferred to the liquidator  

---

### Borrow Rate and Indexed Interest

All rate factors use WAD (`1e18`) scaling. The implementation calculates stored debt as
`totalScaledDebt * borrowIndex / 1e18`. Utilization is zero when `totalLiquidity` is zero, `1e18` when stored debt
is at least total liquidity, and otherwise `storedDebt * 1e18 / totalLiquidity`. The annual rate is:

```text
baseBorrowRate + utilization * borrowRateSlope / 1e18
```

Initialization requires `baseBorrowRate + borrowRateSlope <= 1e18`; utilization is capped at `1e18`, so this also
bounds the implemented annual rate at `1e18` for a valid configuration. The model is linear and has no kink.

For elapsed time `Δt`, a nonzero debt position computes `interestFactor = annualRate * Δt / 365 days`, then
updates the index with the second-order approximation
`borrowIndex * (1e18 + interestFactor + interestFactor² / (2 * 1e18)) / 1e18`. This is neither continuous nor
per-block compounding.

The stored index is checkpointed before `borrow`, `repay`, and `liquidate`. Liquidity deposits and withdrawals,
collateral deposits and withdrawals, view calls, and time passage do not checkpoint it. Consequently the next debt
mutation applies utilization observed at that checkpoint—using then-current total liquidity and stored indexed
debt—to all time since the prior checkpoint. Historical utilization is not recorded or integrated. An intervening
large liquidity deposit can therefore undercharge the preceding period, while a large withdrawal can overcharge
it. Phase 1 deliberately preserves this utilization-checkpointing limitation.

---

### Notes

- This model assumes a simplified single-asset pool  
- Borrower debt uses the indexed interest model above; lender-side yield distribution remains out of scope
