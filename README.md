# lending-protocol-engine

A modular DeFi lending protocol core built in Solidity and Foundry.

Implements the core mechanics of overcollateralized lending:

- ERC-4626 collateral vaults
- oracle-aware health factor accounting
- indexed/scaled debt accounting
- WAD-based interest accrual
- liquidation mechanics with explicit residual debt handling
- fuzz and invariant-tested solvency guarantees

This repository focuses on protocol accounting correctness, solvency preservation, and explicit state-transition safety rather than production feature completeness.

---

# Design Goals

The protocol was designed around four primary constraints:

- accounting correctness
- solvency preservation
- explicit risk modeling
- invariant-tested state transitions

The implementation intentionally prioritizes protocol mechanics and system reasoning over UI, governance, or yield optimization features.

---

# Architecture

```text
┌──────────────────────────────────────────────────────────────┐
│                        LendingPool.sol                       │
│                                                              │
│  depositCollateral()   withdrawCollateral()                  │
│  borrow()              repay()                               │
│  liquidate()           getHealthFactor()                     │
│                                                              │
│  ┌─────────────────┐   ┌────────────────┐                   │
│  │ CollateralVault │   │ Borrow Engine  │                   │
│  │    ERC-4626     │   │ scaledDebtOf[] │                   │
│  │ shares/assets   │   │ borrowIndex    │                   │
│  └────────┬────────┘   └───────┬────────┘                   │
│           │                    │                             │
│           └──────────┬─────────┘                            │
│                      │                                       │
│              ┌───────▼────────┐                              │
│              │  OracleLib.sol │                              │
│              │ staleness +    │                              │
│              │ invalid round  │                              │
│              └───────┬────────┘                              │
│                      │                                       │
│              ┌───────▼────────┐                              │
│              │  IPriceFeed    │                              │
│              │ (Chainlink     │                              │
│              │ compatible)    │                              │
│              └────────────────┘                              │
└──────────────────────────────────────────────────────────────┘
```

## Components

| Contract | Responsibility |
|---|---|
| `LendingPool.sol` | Core lending lifecycle: borrow, repay, liquidate, health factor |
| `CollateralVault.sol` | ERC-4626 collateral custody and share accounting |
| `OracleLib.sol` | Oracle validation, staleness protection, WAD normalization |
| `IPriceFeed.sol` | Chainlink-compatible oracle interface |
| `MockV3Aggregator.sol` | Deterministic testing oracle |

---

# Protocol State Machine

A user position moves through explicit solvency states.

```text
                    depositCollateral()
                          │
                          ▼
                     [COLLATERAL]
                    /            \
            borrow()              withdrawCollateral()
               │                       │
               ▼                       ▼
          [BORROWING]             [WITHDRAWN]
         /     |      \
  repay()   healthy   unhealthy (HF < 1e18)
     │                    │
     ▼                    ▼
[REPAID]           liquidate()
                        │
                   ┌────┴────┐
                   │         │
              solvent   residual debt
               close       remains
```

## Health Factor

The protocol uses a single solvency metric:

```text
HF = (collateralValueUSD × LTV_THRESHOLD) / currentDebtUSD
```

```text
HF ≥ 1e18  →  position is healthy
HF < 1e18  →  position is liquidatable
```

All collateral valuation is performed using live oracle reads at execution time. No collateral value is cached between calls.

---

# Collateral Vault — ERC-4626

Collateral is held inside an ERC-4626 compliant vault.

## Why ERC-4626?

The standard provides:

- deterministic share/accounting semantics
- separation between ownership and asset value
- standardized rounding behavior
- composability with broader DeFi infrastructure

The vault treats:

- shares as ownership
- assets as value

This distinction becomes critical once vault exchange rates diverge over time.

## Liquidation Rounding Safety

Liquidation paths intentionally use `previewWithdraw()` (ceiling rounding).

This ensures a liquidator receives at least the required collateral amount during seizure operations.

Using floor-rounding conversions during liquidation would systematically under-seize collateral and introduce protocol accounting drift across repeated liquidation events.

---

# Debt Accounting Model — Indexed / Scaled Debt

Debt is tracked using a global borrow index and per-user scaled balances inspired by accumulator models used in lending protocols such as Aave and Compound.

## Storage

```solidity
uint256 public borrowIndex;
uint256 public lastBorrowIndexUpdate;

mapping(address => uint256) public scaledDebtOf;
```

---

## Debt Lifecycle

### At borrow

```text
scaledDebtOf[user] = principal × WAD / borrowIndex
```

### Current debt at any point in time

```text
currentDebt[user] = scaledDebtOf[user] × borrowIndex / WAD
```

---

## Why this model?

Naive lending systems mutate every borrower position over time.

Indexed accounting avoids:

- per-user interest mutation
- O(n) debt updates
- scalability bottlenecks
- looping accrual patterns

Debt growth becomes globally composable and gas-efficient.

---

# Interest Accrual Model

The borrow index grows over time through a WAD-based accumulator.

```text
Δt = block.timestamp − lastBorrowIndexUpdate
r  = annualRate / SECONDS_PER_YEAR
```

The implementation uses a second-order approximation to reduce long-window divergence present in naive linear accrual models.

## Critical Invariant

`_updateBorrowIndex()` executes before every debt mutation:

- `borrow()`
- `repay()`
- `liquidate()`

This prevents debt reads and writes against stale index state.

The ordering is enforced structurally in code, not by convention.

---

# Liquidation Engine

A position becomes liquidatable when:

```text
HF < 1e18
```

---

## Liquidation Mechanics

```text
collateralToSeize =
debtToCover × (1 + LIQUIDATION_BONUS) / oraclePrice
```

The liquidation bonus compensates liquidators for:

- gas expenditure
- execution risk
- volatile market conditions

Without a liquidation incentive, unhealthy positions may remain unresolved during stress events.

---

## Residual Debt Handling

When:

```text
collateralToSeize > collateralBalance
```

the protocol:

- caps repayment to available collateral coverage
- closes the operational position
- leaves residual debt explicitly non-zero inside the debt accounting system

Residual debt is intentionally not silently cleared.

This preserves visibility into undercollateralized positions and prevents insolvency from being hidden behind accounting mutations.

---

## Seizure Rounding

Collateral seizure intentionally uses ERC-4626 ceiling rounding behavior.

The protocol must seize at least the calculated collateral amount, never less.

Even small under-seizures compound into meaningful accounting loss across repeated liquidation events.

---

# Oracle Integration

All price reads pass through:

```solidity
OracleLib.getFreshPriceWad()
```

The library performs three validations:

1. Invalid price check
2. Staleness check
3. Invalid round detection

All oracle values are normalized to WAD precision regardless of feed decimals.

## Oracle Safety Checks

```solidity
if (answer <= 0) revert InvalidPrice();

if (
    updatedAt == 0 ||
    block.timestamp - updatedAt > maxStaleness
) revert StalePrice();

if (answeredInRound < roundId)
    revert InvalidRound();
```

Oracle freshness is treated as a solvency requirement, not a UI concern.

Health factor checks remain pure read paths by design. Coupling solvency reads with state mutation would unnecessarily complicate keeper systems and protocol monitoring.

---

# Security Properties

## Checks → Effects → Interactions

All state-mutating functions follow CEI ordering.

External token transfers occur only after internal accounting updates complete.

This ordering reduces exposure to callback-based and hook-based reentrancy vectors.

---

## Solvency Enforcement

The protocol enforces:

- borrow limits
- health factor constraints
- liquidation thresholds

Collateral cannot be withdrawn if doing so would push:

```text
HF < 1e18
```

---

## Index Monotonicity

`borrowIndex` is strictly non-decreasing.

Invariant tests verify that no sequence of accrual operations can decrease the index regardless of time delta.

---

# Test Suite

```text
82 tests — all passing

56  unit  (LendingPool)
 7  unit  (CollateralVault)
10  fuzz
 9  invariant
──
82  total
```

## Coverage Includes

### Unit Tests

- ERC-4626 share accounting
- borrow limits
- partial/full repay
- liquidation paths
- residual debt handling
- oracle staleness
- invalid oracle rounds
- multi-user debt isolation

### Integration Tests

- full lifecycle:
  deposit → borrow → time warp → repay

- liquidation after compounded interest accrual
- residual debt correctness after partial repay
- borrow rejection after accrued debt growth

### Fuzz Tests

- LTV ceiling enforcement
- debt non-negativity
- index monotonicity
- share/asset round-trip correctness

### Invariant Tests

- health factor consistency
- stale oracle rejection
- index-first debt mutation ordering
- residual debt remains non-zero after undercollateralized liquidation

---

# Known Limitations

These limitations are documented intentionally and reflect scoped engineering decisions.

---

## LP Yield Accounting Not Implemented

Borrower debt accrues correctly, but lender-side yield distribution is intentionally omitted.

`totalLiquidity` does not grow over time.

Supporting LP yield correctly would require either:

- a second accumulator index
- or explicit distribution accounting

This concern is intentionally separated from borrower accounting.

---

## Fixed Interest Rate

The protocol uses a fixed borrow rate.

A utilization-based kink model (Aave/Compound style) is the intended production direction but was intentionally excluded from the current scope.

The accumulator architecture itself is rate-agnostic.

---

## No Liquidation Circuit Breaker

The protocol does not implement:

- pause controls
- liquidation throttling
- per-block liquidation caps

Production systems typically require additional protection against oracle manipulation and cascading liquidation scenarios.

---

## Single Collateral Asset

Each deployment supports a single collateral asset.

Multi-asset collateral support would require:

- collateral registries
- weighted valuation models
- isolation mode logic
- eMode-style risk grouping

This is intentionally reserved for future iterations.

---

# Running the Protocol

```bash
# Build
forge build

# Full test suite
forge test -vv

# Fuzz + invariant suite
forge test --match-path "test/fuzz/*" -vv
forge test --match-path "test/invariant/*" -vv

# Gas snapshot
forge snapshot
```

## Requirements

- Solidity `0.8.24`
- Foundry (`forge`, `cast`, `anvil`)

---

# Future Direction

The accounting core was intentionally designed to support extension into more complex lending and RWA financing systems without restructuring debt primitives or oracle infrastructure.

---

# Stack

- Solidity `0.8.24`
- Foundry (`forge`, `cast`, `anvil`)
- OpenZeppelin (`ERC4626`, `SafeERC20`)
- Chainlink `AggregatorV3Interface`
- forge-std