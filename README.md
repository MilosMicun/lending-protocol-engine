# Lending Protocol Engine

An upgradeable overcollateralized lending protocol built with Solidity and Foundry. It demonstrates indexed lending accounting, ERC-4626 collateral custody, oracle validation, invariant testing, UUPS state migration, and Safe-controlled upgrade operations.

The canonical [`LendingPool` proxy](https://sepolia.etherscan.io/address/0x4Ba81845c2E130013EF2Be36e220cA1166E70873#code) is live on Ethereum Sepolia and still delegates to the historical V1 implementation. V1.2 is an implemented, tested, migration-reviewed local upgrade candidate with Safe preparation and verification tooling; it has not been deployed or installed on the public proxy. Any V1.2 deployment and Safe execution is a future, explicitly authorized operation.

## Project status

| Scope | Status |
| --- | --- |
| Public Sepolia system | Canonical ERC-1967 proxy and historical V1 representative flow are live |
| Active implementation | Historical V1 at [`0x4f5c7dC968602b54519F515576FeC936405CB940`](https://sepolia.etherscan.io/address/0x4f5c7dC968602b54519F515576FeC936405CB940#code) |
| Upgrade authority | [Safe 1.4.1](https://sepolia.etherscan.io/address/0xe6E0B9B815666bE6B3dbbf441f678C9618196760), 2-of-2 threshold |
| Local candidate | V1.2 interest accounting, atomic migration, and Safe tooling reviewed and tested locally |
| Public upgrade | No V1.1 or V1.2 implementation has been installed on the Sepolia proxy |

Detailed records:

- [Protocol specification](docs/protocol-spec.md)
- [Public Sepolia deployment evidence](docs/SEPOLIA_DEPLOYMENT.md)
- [UUPS architecture and V1.2 migration guide](docs/UPGRADEABILITY_V1.md)
- [Safe-controlled V1.2 upgrade runbook](docs/SAFE_UPGRADE_RUNBOOK.md)

## Architecture

```text
                              2-of-2 Safe
                                   │ authorizes UUPS upgrades
                                   ▼
Users ─────────► ERC1967Proxy / canonical LendingPool ◄──── debt asset
                 state, debt custody, vault shares
                      │ delegates          │ reads
                      ▼                    ▼
                 implementation       price feed
                      code

                 ERC1967Proxy ──────► CollateralVault ◄──── collateral asset
                    deposits           ERC-4626 custody
```

- The proxy is the permanent user-facing pool, protocol-state, debt-asset custody, and vault-share owner.
- The implementation is a delegatecall code target, not a pool or custody address.
- `CollateralVault` is a separate, non-upgradeable ERC-4626 vault that holds collateral; the proxy owns its shares and records user claims.
- The active authority is configured separately from deployment and may be transferred only through a two-step proposal and acceptance flow.
- The public demo uses fixed-supply, 18-decimal Sepolia-only sdETH and sdUSD assets and the Chainlink Sepolia ETH/USD feed.

Only `LendingPool` is upgradeable. Its implementation constructor disables initializers, and a new proxy is initialized atomically with nonempty constructor calldata.

## Protocol mechanics

Users supply debt-asset liquidity, deposit collateral through the pool into the vault, borrow against that collateral, repay debt, and withdraw only while remaining solvent. An unhealthy third-party position can be liquidated.

```text
healthFactor = collateralValue * liquidationThreshold / currentDebt

healthFactor >= 1e18  healthy
healthFactor <  1e18  liquidatable
```

Debt-free positions return the maximum `uint256` health factor. Borrow admission uses the configured LTV; liquidation eligibility uses the separately configured liquidation threshold.

The pool owns vault shares and tracks each user's claim in `collateralSharesOf`. Deposits that would mint zero shares revert. Withdrawals use ceiling-rounded `previewWithdraw()` and test indebted-user solvency against the assets represented by the remaining shares. Liquidation also uses a ceiling-rounded share cost and reports the vault's actual redeemed asset output.

### Interest accounting versions

The historical V1 deployment uses a WAD index and a second-order annual-interest approximation. Its recorded Sepolia flow remains valid historical evidence. V1 does not checkpoint before liquidity changes, so the utilization observed at the next debt checkpoint can price the still-open preceding interval.

The source-level checkpoint correction settles interest before every utilization-changing mutation: liquidity deposits and withdrawals as well as borrowing, repayment, and liquidation. The ordering is:

```text
settle elapsed time at the pre-mutation rate
  -> store the index and timestamp
  -> mutate liquidity or debt
  -> apply the resulting rate only to future time
```

A liquidity deposit can lower utilization and slow future index growth, but it cannot reduce an index or debt that has already accrued. A withdrawal can similarly raise only the future rate.

V1.2 retains WAD annual-rate inputs and a WAD-stored cumulative index while performing once-per-second compounding with RAY intermediate precision. It uses full-width `Math.mulDiv`, explicit debt-conversion rounding, zero-scaled-amount guards, an 18-decimal debt-asset requirement, and bounded rate, elapsed-time, and debt-quantum domains. See the [interest-accounting specification](docs/protocol-spec.md#7-v12-interest-accounting).

### V1.2 migration

V1.2 must be installed through the canonical proxy with one authorized UUPS `upgradeToAndCall` that invokes `migrateToV1_2()`. The migration settles the elapsed legacy interval with the historical formula, stores that boundary index and timestamp, validates the V1.2 accounting domain, and activates initializer version 2. Existing scaled balances, configuration, authority, custody, and the frozen protocol layout remain in place.

A plain implementation replacement without the migration calldata is not an accepted upgrade path. V1.2 accounting paths fail closed until activation, and a failed atomic migration rolls back the implementation-slot update and all migration writes.

## Oracle and asset boundary

All price reads require a positive answer, a nonzero non-future timestamp, acceptable staleness, and `answeredInRound >= roundId`. Feeds with 0–18 decimals are normalized to WAD; unsupported decimals, overflow, and a zero normalized result revert.

The protocol assumes standard, exact-transfer, non-rebasing ERC-20 assets whose raw units match the oracle quotation. `SafeERC20` handles common return conventions but does not make arbitrary callback-capable or adversarial tokens safe. The contracts have no general reentrancy guard, and external-call ordering is path-specific. Asset selection is therefore a deployment-time trust boundary.

## Testing strategy

The Foundry suite separates evidence by property:

- unit tests cover initialization, accounting domains, rounding, UUPS authorization, storage layout, lending paths, oracle failures, ERC-4626 behavior, and liquidation;
- fuzz tests exercise interest monotonicity, elevated indexes, debt normalization, repayment boundaries, and aggregate rounding;
- invariant campaigns cover accounting identities, index monotonicity, debt isolation, custody coverage, liquidation rejection for healthy positions, and action reachability through a real proxy;
- integration tests cover representative V1/V1.1-to-V1.2 atomic migration and post-activation accounting; and
- script tests cover typed candidate deployment, code-hash authentication, canonical calldata, attestation binding, tracked mapping leaves, custody continuity, failure rollback, and read-only post-verification.

The committed `b33e0f8` baseline passed 408 tests, including 18 invariants; this is a point-in-time result, not a security proof.

```bash
forge build
forge test -vv
forge test --match-path "test/fuzz/*" -vv
forge test --match-path "test/invariant/*" -vv
forge snapshot
```

Requirements: Solidity `0.8.24` and Foundry (`forge`, `cast`, `anvil`).

## Known limitations and non-claims

- This repository and its Sepolia deployment are not represented as audited, formally verified, or production-ready.
- The public evidence covers a V1 deposit, collateral deposit, borrow, and partial repayment, not every path.
- No public liquidation, V1.1 upgrade, or V1.2 upgrade has occurred.
- V1.2 is a local upgrade candidate; public deployment, Safe review, execution, and verification remain future work.
- sdETH and sdUSD are testnet demonstration assets.
- Borrower debt accrues, but lender yield distribution is not implemented; `totalLiquidity` does not grow with accrued interest.
- Each pool supports one collateral asset and has no pause control, close factor, reserves, timelock, or economic-parameter governance.
- Collateral-capped liquidation may leave visible residual debt without a reserve or socialization mechanism.
- The recorded 2-of-2 Safe requires two distinct owner-account approvals, but both owner EOAs are controlled by one operator; see the canonical [deployment limitation](docs/SEPOLIA_DEPLOYMENT.md#10-limitations-and-non-claims).
- Safe control does not remove signer, key-management, transaction-review, or operational risk.

## Stack

- Solidity `0.8.24`
- Foundry
- OpenZeppelin `ERC4626`, `SafeERC20`, `Initializable`, `UUPSUpgradeable`, and `ERC1967Proxy`
- Chainlink-compatible `AggregatorV3Interface`
- forge-std
