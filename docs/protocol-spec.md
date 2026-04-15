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

## 5. Invariants

1. User can never have negative collateral or negative debt  
2. Any user action must result in a position with health factor ≥ 1  
3. Liquidation can never repay more debt or seize more collateral than the position holds  
4. System totals must always match the sum of user balances  
5. NoPosition must always represent zero collateral and zero debt  
6. Collateral seized during liquidation must not exceed user collateral balance  
7. Liquidation must improve health factor or fully close the position  

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

### Notes

- This model assumes a simplified single-asset pool  
- Interest accrual is out of scope and debt is treated as static  