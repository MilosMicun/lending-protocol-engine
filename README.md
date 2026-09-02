# Lending Protocol Engine

An upgradeable overcollateralized lending protocol built with Solidity and Foundry, publicly deployed and validated through a representative on-chain flow on Ethereum Sepolia.

## Project status

| | |
| --- | --- |
| Network | Ethereum Sepolia (`11155111`) |
| Canonical LendingPool | [`0x4Ba81845c2E130013EF2Be36e220cA1166E70873`](https://sepolia.etherscan.io/address/0x4Ba81845c2E130013EF2Be36e220cA1166E70873#code), an ERC-1967 proxy |
| V1 implementation | [`0x4f5c7dC968602b54519F515576FeC936405CB940`](https://sepolia.etherscan.io/address/0x4f5c7dC968602b54519F515576FeC936405CB940#code) |
| Upgrade authority | [Safe 1.4.1](https://sepolia.etherscan.io/address/0xe6E0B9B815666bE6B3dbbf441f678C9618196760), 2-of-2 threshold |
| Verification | sdETH, sdUSD, CollateralVault, the V1 implementation, and ERC1967Proxy source are verified on Etherscan |

The proxy is the user-facing pool and holds protocol state and custody; Etherscan automatically associates it with the verified implementation. The active upgrade authority is the Safe, and the pending authority is the zero address. No public V1-to-V1.1 upgrade has been executed.

A representative Sepolia flow successfully deposited `10,000 sdUSD` of liquidity and `1 sdETH` of collateral, borrowed `1,000 sdUSD`, and partially repaid `250 sdUSD`. Approximately `750 sdUSD` of debt intentionally remains live and accrues interest as public protocol-state evidence. This was not a liquidation and does not represent comprehensive on-chain path coverage.

## What this project demonstrates

- ERC-1967/UUPS proxy architecture with atomic proxy initialization
- Safe-controlled upgrade authorization and a two-step authority-transfer design
- ERC-4626 collateral custody, share accounting, and rounding-aware solvency protection
- Indexed/scaled debt accounting and WAD-based interest accrual
- Chainlink-compatible oracle validation and price normalization
- Health-factor enforcement and collateral-capped liquidation mechanics
- Unit, fuzz, invariant, integration, storage-layout, upgrade-preservation, and deployment-script testing

## Quick links

- [Live Sepolia LendingPool](https://sepolia.etherscan.io/address/0x4Ba81845c2E130013EF2Be36e220cA1166E70873#code)
- [Public deployment evidence](docs/SEPOLIA_DEPLOYMENT.md)
- [Protocol specification](docs/protocol-spec.md)
- [UUPS architecture and storage specification](docs/UPGRADEABILITY_V1.md)
- [Safe upgrade runbook](docs/SAFE_UPGRADE_RUNBOOK.md)

## Architecture

```text
                              2-of-2 Safe
                                   │ authorizes UUPS upgrades
                                   ▼
Users ─────────► ERC1967Proxy / canonical LendingPool ◄──── sdUSD
                 state, sdUSD custody, vault shares          demo liquidity/debt
                      │ delegates          │ reads
                      ▼                    ▼
                 LendingPool V1       Chainlink ETH/USD
                 implementation       price feed
                      code

                 ERC1967Proxy ──────► CollateralVault ◄──── sdETH
                    deposits           ERC-4626              demo collateral
                                       sdETH custody
```

- **ERC1967 proxy:** the canonical user-facing address. It retains LendingPool state, sdUSD custody, CollateralVault shares, and pool-to-vault approvals.
- **LendingPool implementation:** the UUPS code target used through delegate calls. It is not a pool or custody address.
- **CollateralVault:** a separately deployed, non-upgradeable ERC-4626 vault that holds sdETH; the proxy owns its shares and accounts for user claims.
- **Oracle:** the external Chainlink Sepolia ETH/USD feed prices ETH-like demo collateral in USD-like demo debt units.
- **Safe:** the external 2-of-2 upgrade authority. The deployer and demo actor do not receive implicit upgrade permission.
- **Demo assets:** fixed-supply, 18-decimal Sepolia-only sdETH collateral and sdUSD debt/liquidity tokens. They are not production assets.

Only `LendingPool` is upgradeable. Its implementation constructor disables initializers. The deployment script supplies nonempty initialization calldata to the proxy constructor, so the proxy and its ten configuration values—including the initial upgrade authority—are initialized atomically.

## Protocol mechanics

### Position lifecycle and health factor

Users supply sdUSD liquidity, deposit collateral through the pool into the vault, borrow against that collateral, repay debt, and withdraw only while remaining solvent. An unhealthy third-party position can be liquidated.

```text
healthFactor =
    collateralValue × liquidationThreshold / currentDebt

healthFactor >= 1e18  healthy
healthFactor <  1e18  liquidatable
```

Debt-free positions return the maximum `uint256` health factor. Collateral values come from live, validated oracle reads; they are not cached. Borrow limits use the separately configured LTV threshold, while liquidation eligibility uses the liquidation threshold.

### ERC-4626 collateral accounting and rounding

`CollateralVault` treats shares as ownership and assets as value. The pool owns the vault shares and records each user's share claim in `collateralSharesOf`.

A nonzero collateral deposit that would mint zero shares reverts atomically. Withdrawals calculate their share cost with ceiling-rounded `previewWithdraw()` and, for an indebted user, test solvency using the assets represented by the remaining shares. This protects solvency when the vault exchange rate is not 1:1.

Liquidation also uses ceiling-rounded `previewWithdraw()` so the share debit is sufficient for the computed asset seizure. `redeem()` then transfers the assets produced by those shares; the emitted seized-asset amount is the actual vault output.

### Indexed debt

The protocol avoids updating every borrower as time passes. It stores one global `borrowIndex` and scaled balances per borrower:

```text
scaledDebtAdded = borrowedAmount × WAD / borrowIndex
currentDebt     = scaledDebt × currentBorrowIndex / WAD
```

`totalScaledDebt` provides the same accumulator model for system debt. Integer division makes the model explicitly rounding-sensitive; repayment and liquidation tests cover the resulting scaled-debt behavior.

### Interest rate and accrual

Rates and indices use WAD (`1e18`) precision. At an index calculation:

```text
storedDebt = totalScaledDebt × borrowIndex / WAD

utilization = 0                                 if totalLiquidity = 0
utilization = WAD                               if storedDebt >= totalLiquidity
utilization = storedDebt × WAD / totalLiquidity otherwise

annualRate = baseBorrowRate + utilization × borrowRateSlope / WAD
```

Utilization is capped at `WAD`. Initialization requires `baseBorrowRate + borrowRateSlope <= WAD`, so valid configurations cap the linear annual rate at `WAD`; this is not a kink model.

For elapsed time with nonzero scaled debt, `currentBorrowIndex()` applies a second-order approximation:

```text
interestFactor  = annualRate × elapsedSeconds / 365 days
secondOrderTerm = interestFactor² / (2 × WAD)
currentIndex    = borrowIndex × (WAD + interestFactor + secondOrderTerm) / WAD
```

This is neither continuous nor per-block compounding. `borrow()`, `repay()`, and `liquidate()` checkpoint the stored index before mutating debt. Collateral operations, liquidity operations, view calls, and the passage of time do not checkpoint it.

The elapsed interval uses utilization observed at the later debt checkpoint; historical utilization is not integrated. Because liquidity changes do not checkpoint first, a deposit can lower—and a withdrawal can raise—the rate applied to the entire interval since the prior debt checkpoint. This is a documented V1 limitation.

### Liquidation

For a position below the liquidation threshold, a third-party liquidator repays debt and receives collateral with the configured bonus:

```text
repayValueWithBonus = actualRepay × (1 + liquidationBonus)
collateralToSeize   = repayValueWithBonus / oraclePrice
```

If the requested seizure exceeds the borrower's collateral, the protocol caps the seizure at available collateral and reduces the repay amount to the value supportable after the bonus. Any uncovered residual debt remains visible in scaled-debt accounting; it is not silently erased. A zero-value capped repayment reverts with `BadDebt`.

No liquidation has been executed as part of the public Sepolia demonstration.

### Oracle validation and units

All protocol price reads use `OracleLib.getFreshPriceWad()`. A read must have:

- a positive answer;
- a nonzero timestamp that is not in the future;
- an update within the configured maximum-staleness window; and
- `answeredInRound >= roundId`.

Feeds with 0–18 decimals are normalized to WAD. Unsupported decimals, normalization overflow, and a zero normalized result revert.

Oracle normalization does not normalize token raw units against each other. The deployed ETH/USD semantics are appropriate for the 18-decimal ETH-like sdETH collateral and USD-like sdUSD debt asset; arbitrary token and feed combinations require an explicit decimal and quotation compatibility review.

## Initialization and upgrade authority

The V1 initializer receives nine dependency/economic values plus `initialUpgradeAuthority`. It validates and fixes the oracle, vault, debt asset, staleness window, risk parameters, and rate parameters at initialization. V1 has no ordinary post-deployment economic-parameter setters.

Upgrade authorization is separate from economic configuration:

1. The active authority may propose a nonzero pending authority.
2. Only that pending address may accept, at which point it becomes active and the pending value returns to zero.

A pending authority cannot upgrade before acceptance, and there is no renounce or zero-address transfer path. `_authorizeUpgrade()` accepts only the active authority. For the public deployment that authority is the 2-of-2 Safe; the current pending authority is zero.

The repository includes tooling and tests for preparing and validating a minimal storage-compatible V1.1 upgrade, but no public V1-to-V1.1 upgrade has occurred. See the [upgradeability specification](docs/UPGRADEABILITY_V1.md) and [Safe runbook](docs/SAFE_UPGRADE_RUNBOOK.md).

## Testing strategy

The Foundry suite is organized by evidence type rather than a headline aggregate count:

- **Unit:** initialization, proxy authority, UUPS behavior, frozen storage layout, lending actions, interest accrual, oracle failures, ERC-4626 accounting, and liquidation paths.
- **Fuzz:** borrowing and LTV rejection, withdrawal solvency after vault exchange-rate changes, partial and excess repayment, scaled-debt rounding after accrual, healthy-position rejection, collateral-capped liquidation, and liquidity consistency.
- **Invariant:** accounting identities, debt isolation, index monotonicity, custody coverage, healthy-position liquidation rejection, action-level withdrawal checks, and campaign reachability through a real proxy.
- **Integration:** accounting and custody preservation across a real proxy upgrade.
- **Deployment and upgrade scripts:** dependency preflight, atomic initialization, configuration readback, public-flow validation, upgrade preparation, state fingerprinting, authority execution, and read-only post-upgrade verification.

The invariant configuration uses 64 runs at depth 128 with `fail_on_revert = false`; reachability assertions ensure selected successful actions occur at campaign level. These tests provide scoped evidence, not formal verification or proof over arbitrary integrations.

```bash
forge build
forge test -vv
forge test --match-path "test/fuzz/*" -vv
forge test --match-path "test/invariant/*" -vv
forge snapshot
```

Requirements: Solidity `0.8.24` and Foundry (`forge`, `cast`, `anvil`).

## Asset and callback boundary

V1 is designed for standard, exact-transfer, non-rebasing ERC-20 assets whose raw units and oracle quotation are compatible. It does not reconcile nominal accounting changes against token balance deltas, so fee-on-transfer, taxed, deflationary, reflective, or rebasing assets can invalidate accounting and solvency assumptions.

`SafeERC20` improves compatibility with common ERC-20 return conventions. It does not make arbitrary or adversarial tokens safe, prevent callbacks, or provide reentrancy protection. The production contracts have no general reentrancy guard, and their external-call ordering is path-specific. Asset selection is therefore a deployment-time trust and compatibility boundary, documented in the [asset dependency preflight](docs/SAFE_UPGRADE_RUNBOOK.md#asset-dependency-preflight).

## Known limitations and non-claims

- This repository and its Sepolia deployment are not represented as audited or production ready.
- The public flow covers deposit, collateral deposit, borrow, and partial repayment—not every protocol path.
- No public liquidation or public V1-to-V1.1 upgrade has been executed.
- sdETH and sdUSD are fixed-supply testnet demonstration assets, not production assets.
- Borrower debt accrues, but lender yield distribution is not implemented; `totalLiquidity` does not grow with accrued interest.
- Liquidity changes do not checkpoint the borrow index, and later-checkpoint utilization applies to the prior elapsed interval.
- Each pool deployment supports one collateral asset.
- There are no pause controls, liquidation throttles, per-block caps, general reentrancy guard, or governance-controlled economic setters.
- Safe control reduces unilateral upgrade authority but does not remove signer, key-management, transaction-review, or operational risk.
- Residual debt can remain after collateral-capped liquidation and has no separate socialization or reserve mechanism.

## Stack

- Solidity `0.8.24`
- Foundry
- OpenZeppelin `ERC4626`, `SafeERC20`, `Initializable`, `UUPSUpgradeable`, and `ERC1967Proxy`
- Chainlink-compatible `AggregatorV3Interface`
- forge-std
