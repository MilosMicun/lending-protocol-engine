# lending-protocol-engine

A modular DeFi lending protocol core built in Solidity and Foundry.

Implements the core mechanics of overcollateralized lending:

- ERC-4626 collateral vaults
- oracle-aware health factor accounting
- indexed/scaled debt accounting
- WAD-based interest accrual
- liquidation mechanics with explicit residual debt handling
- fuzz and invariant tests for selected accounting and solvency properties

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

`LendingPool` is used through an ERC-1967 proxy and is the only UUPS-upgradeable protocol contract.
`CollateralVault` is deployed separately through its constructor and is not upgradeable. The `LendingPool`
implementation constructor only disables initializers; deployment passes nonempty initialization calldata to the
proxy constructor so the proxy is atomically initialized with the nine economic/dependency parameters and the
tenth `initialUpgradeAuthority` parameter. The proxy is the canonical pool and holds pool state, debt-asset
custody, collateral-vault shares, and pool-to-vault approvals. Implementation addresses are code targets only and
must not receive protocol custody or approvals.

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
scaledDebtOf[user] += borrowedAmount × WAD / borrowIndex
```

### Current debt at any point in time

```text
currentDebt[user] = scaledDebtOf[user] × currentBorrowIndex / WAD
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

# Interest Rate and Accrual Model

Rates and index factors use WAD (`1e18`) scaling. At an index checkpoint, the implementation derives utilization
from the currently stored accounting state:

```text
storedDebt = totalScaledDebt × borrowIndex / WAD

utilization = 0                                             if totalLiquidity = 0
utilization = WAD                                           if storedDebt >= totalLiquidity
utilization = storedDebt × WAD / totalLiquidity             otherwise

annualRate = baseBorrowRate + utilization × borrowRateSlope / WAD
```

Utilization is therefore capped at `WAD`. Initialization requires `baseBorrowRate + borrowRateSlope <= WAD`, so
the implemented annual rate is also at most `WAD` for a valid configuration. This is a linear utilization model,
not a kink model.

For nonzero elapsed time and nonzero `totalScaledDebt`, `currentBorrowIndex()` applies a second-order
elapsed-time approximation:

```text
Δt = block.timestamp − lastBorrowIndexUpdate
interestFactor = annualRate × Δt / 365 days
secondOrderTerm = interestFactor² / (2 × WAD)
currentBorrowIndex = borrowIndex × (WAD + interestFactor + secondOrderTerm) / WAD
```

If no time has elapsed or `totalScaledDebt` is zero, it returns the stored `borrowIndex`. This is neither
continuous compounding nor per-block compounding.

## Borrow-index checkpoints

`_updateBorrowIndex()` executes before each implemented debt mutation:

- `borrow()`
- `repay()`
- `liquidate()`

It stores the value returned by `currentBorrowIndex()` and advances `lastBorrowIndexUpdate` to the current block
timestamp. Collateral deposits and withdrawals, liquidity deposits and withdrawals, view calls, and the passage
of time do not checkpoint the stored index.

The rate applied to the entire elapsed interval uses utilization observed when the later checkpoint occurs. The
contract does not record or integrate historical utilization. Because liquidity changes do not checkpoint first,
an intervening liquidity deposit or withdrawal changes the utilization used for time since the previous debt
checkpoint; a large deposit can undercharge that preceding period, while a large withdrawal can overcharge it.
This is a deliberate locked Phase 1 utilization-checkpointing limitation.

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

# Supported ERC-20 Asset Boundary (Phase 1)

Phase 1 does not support arbitrary ERC-20 tokens. Both the configured collateral asset and debt asset must satisfy all of the following integration requirements:

- `transfer` and `transferFrom` must have standard ERC-20 call behavior and must move exactly the requested amount: the sender is debited by that amount and the recipient is credited by that amount;
- transfers must not charge fees or taxes, burn value, reflect value to holders, or apply any other sender-side or recipient-side deduction;
- balances must not change autonomously through positive or negative rebasing; and
- token raw units, token decimals, and the price feed's quotation must be compatible with the pool's existing accounting and oracle normalization.

A successful ERC-20 call only shows that the call did not revert and returned an accepted value. It does not establish exact-transfer, non-rebasing, or unit compatibility. These requirements are an explicit deployment and asset-integration constraint; the contracts do not dynamically enforce them for every possible token implementation.

The boundary follows from nominal accounting. The pool credits liquidity and shares, creates or clears debt, and calculates collateral seizure using requested amounts. The pool and the ERC-4626 vault do not reconcile those state changes against token balance deltas. A fee-on-transfer asset can therefore make recorded accounting exceed custody or make a recipient receive less than the protocol records. A rebasing asset can change custody without a matching accounting transition. Either case can invalidate solvency calculations and cause incorrect withdrawals, repayments, borrowing availability, or liquidation outcomes.

Oracle answers are normalized to WAD, but collateral-token and debt-token raw units are not normalized against each other. The pool computes `collateralRawAmount * priceWad / 1e18` and compares the result directly with debt raw units. The selected token decimals and feed quotation must make that result a debt-asset raw-unit amount across the intended price range. With a conventional feed quoting whole debt tokens per whole collateral token, this ordinarily requires matching collateral and debt decimals; matching decimals alone does not prove compatibility.

Before deployment or configuration, the deployment operator and the reviewers approving the asset dependencies must verify and retain evidence for contract identity, deployed bytecode, decimals, exact transfers in every direction used by the pool and vault, absence of rebasing or autonomous balance changes, and oracle/token unit compatibility. The operational checklist and the evidence required for the future Sepolia demonstration are in [`docs/SAFE_UPGRADE_RUNBOOK.md`](docs/SAFE_UPGRADE_RUNBOOK.md#asset-dependency-preflight).

---

# Security Properties

## External-call ordering and callbacks

External-call ordering is execution-path-specific; the implementation does not provide universal
checks-effects-interactions ordering:

- `depositLiquidity()` calls the debt token before crediting liquidity accounting.
- `depositCollateral()` calls the collateral token for `transferFrom` and approval, then calls
  `CollateralVault.deposit()`, before crediting pool collateral-share accounting. The ERC-4626 deposit itself
  transfers underlying assets before minting vault shares.
- `withdrawCollateral()` performs external vault views and, when debt exists, oracle reads before calling
  `CollateralVault.withdraw()`; only after that state-changing vault call returns does the pool reduce its share
  accounting, followed by the final collateral-token transfer.
- `borrow()` may checkpoint the borrow index before external vault/oracle reads, then records debt before the final
  debt-token transfer. `withdrawLiquidity()` similarly reduces liquidity accounting before its final token
  transfer.
- `repay()` checkpoints the index and reduces debt before collecting debt tokens.
- `liquidate()` may checkpoint the index before external oracle/vault reads, then reduces debt and collateral
  accounting before collecting debt tokens and calling `CollateralVault.redeem()`. ERC-4626 withdrawal/redemption
  burns vault shares before transferring underlying assets.

Oracle calls and ERC-4626 preview/conversion calls are external view calls. Solidity executes these calls in static
context, but their position still matters when describing the complete execution path.

The current production contracts have no reentrancy guard or equivalent lock. `SafeERC20` checks low-level ERC-20
call success and accepts supported return-value conventions; it does not prevent token hooks, arbitrary callbacks,
or reentrancy. Consequently, this documentation does not claim complete callback safety or protection from
malicious tokens. Configured assets must satisfy the narrower [Phase 1 supported-asset boundary](#supported-erc-20-asset-boundary-phase-1).

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

The invariant suite asserts that `currentBorrowIndex() >= borrowIndex` and `borrowIndex >= WAD` for the generated
states. This is the exact tested monotonicity property; it is not a proof over every possible execution sequence.

---

# Test Suite

```text
Validation checkpoint: commit 78d6ef6, 2026-09-01

106  unit
 11  fuzz
  9  invariant
  1  integration
 36  script
───
163  total: 163 passed, 0 failed, 0 skipped
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
- utilization-sensitive borrow rates and elapsed-time index accrual
- upgrade authority, UUPS upgrade behavior, and frozen storage layout

### Fuzz Tests

- borrow accounting and LTV rejection
- partial repayment, overpayment, and scaled-debt rounding after accrual
- healthy-position rejection and collateral-capped liquidation
- available-liquidity consistency across borrow and repay

### Integration and Script Tests

- live accounting and custody preservation across a real proxy upgrade
- deployment preflight, atomic proxy initialization, and configuration readback
- V1.1 upgrade preparation, authority execution, state fingerprinting, and read-only verification

### Invariant Tests

Foundry is configured for 64 runs at depth 128. Effective configuration reports `fail_on_revert = false`; zero
handler reverts is therefore not itself an enforced invariant. The direct validation checkpoint and explicit seeds
`0x1` through `0x5` each completed all nine invariants with 8,192 calls and zero reported handler reverts.

The handler targets eight actions through the real proxy: `depositLiquidity`, `depositCollateral`, `borrow`,
`repay`, `withdrawLiquidity`, `withdrawCollateral`, `liquidate`, and `warpTime`. Three tracked users act as
borrowers, collateral depositors, repayers, and external liquidity providers. The handler contract acts as the
liquidator and its borrow-capacity helper can also deposit liquidity from the handler address, so the
liquidity-total invariant includes the handler balance as well as the three users.

The suite's `afterInvariant()` checks campaign-level reachability: at least one attempted and successful borrow;
at least one attempted and successful liquidation; at least two successful external liquidity deposits from at
least two distinct user providers; and at least one successful liquidity withdrawal and collateral withdrawal.
These assertions aggregate across a generated invariant campaign; they do not require every random run to reach
each action. Repay, direct collateral-deposit, and time-warp actions exist in the handler but have no explicit
reachability counter or assertion. Repayment behavior is covered separately by unit and fuzz tests.

The nine enforced invariant functions assert only that:

1. available liquidity does not exceed total liquidity;
2. total scaled debt equals the sum of the three tracked users' scaled debt;
3. total current debt equals the sum of those users' current debt within an absolute tolerance of three units;
4. total collateral shares equal the sum of those users' collateral shares;
5. total liquidity equals the handler's liquidity balance plus the three tracked users' balances;
6. the computed current borrow index is at least the stored index, and the stored index is at least `WAD`;
7. a tracked user with zero scaled debt also has zero current debt;
8. the pool's debt-asset balance, plus a one-unit tolerance per successful handler borrow, covers available
   liquidity; and
9. liquidating a tracked debtor whose health factor is at least `WAD` reverts with `PositionNotLiquidatable`.

The handler additionally checks accounting and custody postconditions after each successful liquidity or
collateral withdrawal. Those action-local assertions and the reachability checks above are not additional
`invariant_*` functions.

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

## Utilization Checkpointing

The protocol uses the linear utilization-based borrow rate described above, but it checkpoints the stored borrow
index only on borrow, repay, and liquidation. Liquidity and collateral operations do not create checkpoints. A
later debt mutation applies then-current utilization to all elapsed time since the previous checkpoint rather than
integrating historical utilization. A large intervening deposit can undercharge the preceding period, while a
large withdrawal can overcharge it. Phase 1 deliberately preserves this limitation.

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
