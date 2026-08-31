# LendingPool UUPS Upgradeability V1

## 1. Purpose and portfolio evolution

This document is the authoritative repository-local specification for Phase 1 of converting `LendingPool` to a UUPS/ERC-1967 architecture. The repository and its Git history remain the existing lending-protocol portfolio project; upgradeability is a new development phase, not a replacement project.

There is no live deployment, existing proxy, or on-chain state to migrate. The locked legacy storage prefix exists to preserve the current contract's layout and to establish a stable base for later implementation versions, not to support a migration of deployed state. Phase 1 later concludes with a new public Sepolia portfolio deployment under Section 11; that educational testnet deployment is not a migration.

This specification separates four categories:

- **Current behavior** is behavior proven by the current Solidity sources, compiler storage-layout report, and baseline tests.
- **Locked Phase 1 behavior** is required for the UUPS conversion even where the implementation does not exist yet.
- **Known pre-existing limitations** are current economic or accounting characteristics that Phase 1 must preserve rather than repair.
- **Future work** is governed by the compatibility rules in this document but is not part of Phase 1.

Phase 1 does not claim production readiness or formal verification.

## 2. Current architecture

The current `LendingPool` is a directly deployed, constructor-configured contract. Its constructor takes nine parameters, validates them, derives `collateralAsset` from `vault.asset()`, assigns configuration, initializes `borrowIndex` to `1e18`, and initializes `lastBorrowIndexUpdate` to `block.timestamp`.

`LendingPool` holds debt-asset token balances directly. When collateral is deposited, it temporarily receives the collateral asset, approves `CollateralVault`, deposits into that vault, and owns the resulting ERC-4626 shares. User claims are represented by the pool's mappings; users do not directly own the corresponding vault shares.

`CollateralVault` is a separately deployed, constructor-configured ERC-4626 contract. It is not upgradeable and must remain non-upgradeable in Phase 1. The oracle and token contracts also remain external dependencies of `LendingPool`.

The current repository has no upgrade authority, proxy, initializer, implementation version, administrative parameter setters, or deployment migration path. Current tests instantiate `LendingPool` directly and cover constructor validation, collateral and liquidity flows, borrowing, repayment, liquidation, interest accrual, fuzz cases, and accounting invariants.

## 3. Target UUPS/ERC1967 architecture

The final canonical Phase 1 architecture consists of:

1. a newly deployed `LendingPool` implementation that uses the vendored OpenZeppelin Contracts 5.6.1 `Initializable` and `UUPSUpgradeable` primitives;
2. a real vendored OpenZeppelin Contracts 5.6.1 `ERC1967Proxy`; and
3. the existing, separately deployed, non-upgradeable `CollateralVault`.

All user and integrator calls to the canonical pool must target the proxy. The proxy delegates execution to the implementation while retaining all pool state, token balances, approvals, and vault-share ownership at the proxy address. The implementation address is code only and must not be used as a pool or custody address.

OpenZeppelin 5.6.1 provides the required mechanics:

- `Initializable` stores initialization state in its own ERC-7201 namespace, so inheriting it does not consume a legacy linear storage slot.
- `UUPSUpgradeable` has no layout-bearing mutable storage; its context guard is an immutable value stored in implementation bytecode. It exposes `upgradeToAndCall(address,bytes)`, requires proxy execution, and checks the new implementation through ERC-1822 `proxiableUUID()`.
- `ERC1967Proxy` stores its implementation in the ERC-1967 implementation slot and delegates nonempty constructor `_data` to the implementation. In the vendored 5.6.1 version, empty `_data` is rejected by default.

Only `LendingPool` becomes upgradeable. Constructor-based `Ownable`, or any other inheritance that inserts linear state before the legacy prefix, is forbidden.

After local tests and adversarial review pass, this architecture must be demonstrated in a public Sepolia portfolio deployment. Sepolia is the locked Phase 1 demonstration network, but it does not make the system production-ready.

The selected Sepolia upgrade authority is an official Safe configured with two distinct development EOA owners and a 2-of-2 threshold. The Safe is external infrastructure: the repository does not implement Safe, a multisig, governance, or a timelock, and this selection does not expand the core protocol scope.

## 4. Initialization specification

The implementation constructor must contain no configuration or state initialization other than a call to `_disableInitializers()`. This locks the implementation's own `Initializable` namespace and makes direct calls to `initialize(...)` revert.

The proxy-facing initializer must have the same nine constructor-equivalent configuration parameters, with their existing types and order, followed by one infrastructure parameter for the initial upgrade authority:

```solidity
function initialize(
    address priceFeed_,
    address vault_,
    address debtAsset_,
    uint256 maxPriceStaleness_,
    uint256 ltvBps_,
    uint256 liquidationThresholdBps_,
    uint256 liquidationBonusBps_,
    uint256 baseBorrowRate_,
    uint256 borrowRateSlope_,
    address initialUpgradeAuthority_
) external initializer;
```

`initialize(...)` must preserve the constructor's checks exactly:

- `priceFeed_`, `vault_`, and `debtAsset_` must be nonzero, otherwise `ZeroAddress()` reverts.
- `maxPriceStaleness_` must be nonzero, otherwise `InvalidStalenessWindow()` reverts.
- each risk parameter must be nonzero; LTV must be lower than the liquidation threshold; the liquidation threshold must be at most `10_000`; and the liquidation bonus must be at most `10_000`. Invalid values revert with `InvalidRiskParameters()`.
- `baseBorrowRate_ + borrowRateSlope_` must be at most `1e18`, otherwise `InvalidInterestRateModel()` reverts. Phase 1 must preserve the current checked-arithmetic behavior of this expression.
- `initialUpgradeAuthority_` must be nonzero, otherwise `InvalidUpgradeAuthority(initialUpgradeAuthority_)` reverts.

After validation, the initializer must preserve every current assignment and initial value:

- `priceFeed = IPriceFeed(priceFeed_)`;
- `vault = CollateralVault(vault_)`;
- `collateralAsset = IERC20(vault.asset())`;
- `debtAsset = IERC20(debtAsset_)`;
- `maxPriceStaleness = maxPriceStaleness_`;
- the three risk parameters equal their inputs;
- `borrowIndex = 1e18`;
- `lastBorrowIndexUpdate = block.timestamp`;
- `baseBorrowRate` and `borrowRateSlope` equal their inputs; and
- all totals and mappings retain their Solidity zero initial values.

The initializer must atomically store `initialUpgradeAuthority_` as the active upgrade authority and initialize the pending-authority field to the zero-value no-pending sentinel. It must not derive either authority value from `msg.sender`. The proxy deployer and configured initial authority are independent addresses and may differ; for example, a deployment account or factory may deploy the proxy while a multisig is explicitly configured as the initial authority.

For the public Sepolia demonstration, the deployment account and the Safe must be distinct, and the Safe address must be passed explicitly as `initialUpgradeAuthority_`. The deployer receives no authority from broadcasting the deployment.

The initializer is version 1 and must succeed exactly once in proxy storage. A second proxy call to it must revert with OpenZeppelin's `InvalidInitialization()`. The implementation's constructor-time `_disableInitializers()` affects only implementation storage and does not prevent the constructor delegatecall from initializing proxy storage.

## 5. Upgrade authorization model

Phase 1 uses a configurable, two-step upgrade authority. The required public API is:

```solidity
function upgradeAuthority() public view returns (address);
function pendingUpgradeAuthority() public view returns (address);
function proposeUpgradeAuthority(address newAuthority) external;
function acceptUpgradeAuthority() external;
```

The required new errors and events are:

```solidity
error UnauthorizedUpgradeAuthority(address caller);
error InvalidUpgradeAuthority(address authority);
error NotPendingUpgradeAuthority(address caller);

event UpgradeAuthorityTransferStarted(
    address indexed currentAuthority,
    address indexed pendingAuthority
);
event UpgradeAuthorityTransferred(
    address indexed previousAuthority,
    address indexed newAuthority
);
```

Only the active authority may call `proposeUpgradeAuthority`. The proposed address must be nonzero and must become the pending authority; the proposal emits `UpgradeAuthorityTransferStarted`. A later valid proposal by the active authority may replace the earlier pending address.

Only the currently pending address may call `acceptUpgradeAuthority`. Acceptance makes it the active authority, clears the pending nomination, and emits `UpgradeAuthorityTransferred`. Before acceptance, a pending authority has no upgrade permission. There is no renounce function and no transfer path to the zero address.

The zero value returned by `pendingUpgradeAuthority()` means that no nomination is pending; it is a sentinel, not a pending authority. Accordingly, neither the active authority nor any nominated pending authority may be set to the zero address. Clearing the nomination after acceptance restores the no-pending sentinel and is not a zero-address nomination.

`_authorizeUpgrade(address)` must authorize only when `msg.sender == upgradeAuthority()`. No pending authority, proxy deployer, proxy admin, token holder, vault owner, or other address receives implicit permission. In particular, deploying the proxy confers no upgrade permission unless that address was separately supplied as `initialUpgradeAuthority_` or later accepted a valid two-step transfer. Unauthorized calls must revert with `UnauthorizedUpgradeAuthority(msg.sender)`.

On Sepolia, the Safe is the only active upgrade authority and both Safe owners must confirm under its 2-of-2 policy. Foundry may deploy implementations and prepare an exact Safe transaction, but it must never receive or impersonate the Safe authority and must not consume an authority private key or mnemonic. Safe execution is external to the repository tooling.

## 6. ERC-7201 authority storage specification

Upgrade-authority state must not be declared as ordinary linear state. It must use this custom ERC-7201 namespace and structure:

```solidity
/// @custom:storage-location erc7201:lending.protocol.storage.LendingPoolUpgradeAuthority
struct UpgradeAuthorityStorage {
    address activeAuthority;
    address pendingAuthority;
}
```

The namespace identifier is locked as:

```text
lending.protocol.storage.LendingPoolUpgradeAuthority
```

Its storage location is derived using the ERC-7201 formula:

```text
keccak256(
    abi.encode(uint256(keccak256("lending.protocol.storage.LendingPoolUpgradeAuthority")) - 1)
) & ~bytes32(uint256(0xff))
```

The precomputed location is:

```text
0x8000ce11f38414f298b74975bfaea500fcdbebb431834e96f66ac2883c9bb800
```

The implementation must use a private constant with that value and an internal/private storage accessor that assigns the structure's `.slot` to the constant. The active authority occupies offset 0 of the namespace root. Because a second 20-byte address does not fit in the 12 bytes remaining in that slot, the pending authority occupies offset 0 of the next slot. No authority field may be added to slots 0–17 or as a new ordinary linear field.

This namespace is distinct from OpenZeppelin's `openzeppelin.storage.Initializable` namespace and from the ERC-1967 implementation slot. Tests must verify the formula and ensure that the namespaces and ERC-1967 slot do not collide.

## 7. Exact legacy storage layout table for slots `0–17`

The following is the actual output model reported by running `forge inspect src/core/lending/LendingPool.sol:LendingPool storage-layout` with the repository's Solidity 0.8.24 configuration before Phase 1 changes. Every entry matches the current compiler report.

| Slot | Offset | Bytes | Field | Compiler-reported type |
|---:|---:|---:|---|---|
| 0 | 0 | 32 | `ltvBps` | `uint256` |
| 1 | 0 | 32 | `liquidationThresholdBps` | `uint256` |
| 2 | 0 | 32 | `liquidationBonusBps` | `uint256` |
| 3 | 0 | 20 | `vault` | `contract CollateralVault` |
| 4 | 0 | 20 | `priceFeed` | `contract IPriceFeed` |
| 5 | 0 | 20 | `debtAsset` | `contract IERC20` |
| 6 | 0 | 20 | `collateralAsset` | `contract IERC20` |
| 7 | 0 | 32 | `maxPriceStaleness` | `uint256` |
| 8 | 0 | 32 | `borrowIndex` | `uint256` |
| 9 | 0 | 32 | `lastBorrowIndexUpdate` | `uint256` |
| 10 | 0 | 32 | `totalCollateralShares` | `uint256` |
| 11 | 0 | 32 | `totalLiquidity` | `uint256` |
| 12 | 0 | 32 | `baseBorrowRate` | `uint256` |
| 13 | 0 | 32 | `borrowRateSlope` | `uint256` |
| 14 | 0 | 32 | `totalScaledDebt` | `uint256` |
| 15 | 0 | 32 | `scaledDebtOf` mapping seed | `mapping(address => uint256)` |
| 16 | 0 | 32 | `collateralSharesOf` mapping seed | `mapping(address => uint256)` |
| 17 | 0 | 32 | `liquidityBalanceOf` mapping seed | `mapping(address => uint256)` |

Constants do not occupy storage. The legacy prefix ends after the mapping seed at slot 17.

## 8. Storage compatibility rules

Slots 0–17 are the immutable V1 legacy prefix. Phase 1 and all future implementations must not:

- reorder or delete a legacy field;
- change a legacy field's type, width, or visibility in a way that changes its storage or ABI;
- insert a field before or between legacy fields;
- change a mapping's key or value type;
- introduce inherited linear state before the legacy prefix; or
- repurpose any legacy slot or mapping seed.

Inheriting the vendored `Initializable` and `UUPSUpgradeable` is permitted because their current 5.6.1 implementations do not add mutable linear storage: initialization data is namespaced and the UUPS context value is immutable. Any future dependency update must be reviewed from source and must not be assumed layout-compatible merely because its import path or contract name is unchanged.

New administrative state must use a documented ERC-7201 namespace. Future economic state may use a new ERC-7201 namespace or be appended after slot 17 only after an explicit versioned specification and storage-layout review. Namespaces must be unique, formula-derived, documented with `@custom:storage-location`, and collision-tested.

Before and after every implementation change, the compiler storage-layout output must be captured and compared. Mapping contents must be checked through representative keys because a table can show a mapping seed without proving stored entries remain readable.

## 9. Preserved V1 economic behavior

Phase 1 changes dispatch and initialization, not economics. Through the proxy, all existing public/external business functions, getters, custom errors, and business-event signatures must remain ABI-compatible and retain their current behavior.

In particular, Phase 1 preserves:

- constructor-equivalent validation and initial configuration;
- ERC-4626 collateral share accounting and proxy custody of vault shares;
- lender balances as nominal `liquidityBalanceOf` amounts and `totalLiquidity` accounting;
- scaled debt, global borrow-index accrual, and the current second-order interest approximation;
- the current points at which `_updateBorrowIndex()` is called;
- current borrow, repay, withdrawal, and liquidation checks;
- every current integer-division direction and rounding result;
- current oracle normalization and freshness checks;
- collateral-capped liquidation and visible residual debt; and
- current token transfer, approval, and vault interaction behavior, with `address(this)` resolving to the proxy.

The only permitted ABI additions are initializer/UUPS interfaces and the explicitly new upgrade-authority functions, errors, and events defined in this specification. Existing custom error selectors and business event signatures must not change.

## 10. Explicit out-of-scope list

Phase 1 must not add, remove, or alter any of the following:

- supplier-share accounting or lender yield distribution;
- protocol reserves, reserve factors, or treasury accounting;
- a liquidation close factor;
- a terminal bad-debt regime, socialization, write-off, or recovery mechanism;
- borrow-index checkpoint rules or new checkpoint triggers;
- borrow, repay, or liquidation rounding;
- liquidation mathematics or health-factor formulas;
- economic parameter setters or governance over economic parameters;
- changes to oracle or token decimal assumptions;
- an upgradeable `CollateralVault`;
- migration of a live deployment or legacy on-chain state;
- custom proxy implementations or an override that allows an uninitialized `ERC1967Proxy`;
- production-readiness or formal-verification claims; and
- remediation of any limitation listed in Section 14.

The V1.1 test implementation may add only one minimal, harmless version or sentinel function that proves calls through the proxy use the new implementation. It must not add economic behavior or mutate existing accounting state.

## 11. Required proxy deployment properties

A canonical deployment must satisfy all of these properties:

1. Deploy a locked `LendingPool` implementation whose constructor calls only `_disableInitializers()`.
2. Deploy the separately configured, non-upgradeable `CollateralVault`.
3. ABI-encode `initialize(...)` with the nine validated constructor-equivalent values followed by the explicitly selected, nonzero `initialUpgradeAuthority_`.
4. Pass that nonempty payload as `_data` to the real `ERC1967Proxy` constructor in the same transaction that creates the proxy.
5. Treat any initialization failure, including a zero initial authority, as an atomic deployment failure; no usable uninitialized proxy may remain.
6. Use the proxy address as the canonical `LendingPool` address for users, token approvals, monitoring, and all integrations.
7. Permit the proxy deployer and `initialUpgradeAuthority_` to be different addresses. Deployment creates no implicit authority, and the configured address alone is the initial authority.
8. Confirm the proxy's ERC-1967 implementation slot points to the intended implementation and its code is nonempty.
9. Confirm all nine constructor-equivalent configuration results, the derived collateral asset, initial index/timestamp, active authority, and zero pending-authority sentinel through proxy calls.
10. Confirm direct implementation initialization reverts, deployment causes no implementation custody delta, and any unchanged unsolicited token or vault-share dust is recorded separately from protocol custody.
11. Publish or record the proxy and implementation addresses distinctly; never present the implementation as the canonical pool.

The vendored OpenZeppelin 5.6.1 proxy rejects empty constructor `_data` by default. Phase 1 must use that default and must not override `_unsafeAllowUninitialized()`.

### Sepolia portfolio deployment

Only after all local unit, fuzz, invariant, proxy, upgrade, and adversarial tests pass and the implementation receives an adversarial review may Phase 1 proceed to its concluding public Sepolia portfolio deployment. The Sepolia exercise must:

1. deploy the non-upgradeable `CollateralVault` and any required testnet-only token, oracle, or other dependency;
2. clearly label every testnet-only dependency, record its purpose and address, and prevent it from being mistaken for a production dependency;
3. deploy the locked V1 `LendingPool` implementation;
4. deploy a real `ERC1967Proxy` with nonempty constructor `_data` that atomically invokes the ten-parameter initializer, including the explicitly configured initial authority;
5. verify the proxy's implementation slot, initialized configuration, active authority, zero pending sentinel, and canonical status before any lending flow;
6. execute a representative lending flow through the proxy, including liquidity deposit, collateral deposit, borrow, and repayment, while retaining enough nonzero state and custody for meaningful upgrade-preservation checks;
7. use an official Safe with two distinct development EOA owners and a 2-of-2 threshold as the sole active upgrade authority, while keeping the implementation deployer separate and unauthorized;
8. use the deploy-and-prepare tooling to deploy a compatible, behaviorally minimal V1.1 implementation that introduces no new mutable storage declarations and preserves the complete V1 storage layout, and produce the exact proxy target, zero value, `upgradeToAndCall` calldata, and pre-upgrade state fingerprint;
9. independently review the prepared chain, Safe, proxy, current and proposed implementations, authorities, target, value, selector, arguments, UUID, version, and fingerprint before either Safe owner confirms;
10. obtain both Safe confirmations and execute the reviewed V1-to-V1.1 transaction externally through Safe; Foundry must not execute or impersonate this authority action;
11. run the independent read-only verifier immediately after execution, without `--broadcast`, and require the expected V1.1 implementation and version, unchanged authorities, and matching cross-run state fingerprint;
12. record the proxy, V1 implementation, and V1.1 implementation addresses as three distinct roles, and also record the Safe, its owners and threshold, the vault, and testnet-dependency addresses;
13. record the relevant deployment, initialization, representative-flow, implementation-deployment, prepared transaction, state fingerprint, Safe confirmation/execution, and verification evidence;
14. perform explorer source verification for the proxy, V1 implementation, V1.1 implementation, vault, and repository-owned testnet dependencies when supported by the available tooling, and record any tooling limitation that prevents verification; and
15. publish an explicit notice that the Sepolia deployment is educational portfolio infrastructure, uses testnet-only assets or dependencies where identified, and is not production-ready.

The on-chain demonstration must use the proxy as the canonical pool and custody address throughout. Deployment, preparation, and upgrade execution must not transfer protocol assets, approvals, or vault shares to either implementation. Unchanged unsolicited token or vault-share dust may already exist at an implementation address and must be recorded rather than treated as protocol custody. Any implementation custody delta caused during the controlled workflow must fail validation. Sepolia addresses and transaction hashes are deployment artifacts to be recorded during Phase 1 implementation; this specification does not invent them in advance.

Preparation, external Safe execution, and verification must occur in a controlled state-freeze window. The cross-run fingerprint binds the chain, proxy, expected old and new implementations, legacy slots 0–17, active and pending authorities, configuration, aggregate accounting, selected proxy/vault custody observations, and old/new implementation custody balances. The ERC-1967 implementation-slot value is intentionally excluded because it must change; the verifier checks that slot independently. Unchanged unsolicited implementation dust is accepted, while changes to fingerprinted protocol state or custody, including legitimate intervening activity, cause a mismatch. Raw mapping seed slots do not enumerate or cryptographically prove every mapping entry, so representative positions remain covered separately by integration tests. This fingerprint is operational evidence, not formal verification.

If state changes before Safe execution, the stale prepared transaction and its fingerprint must not be used. Preparation must be rerun, and only the newly deployed V1.1 implementation, calldata, and state hash may proceed through a fresh review. A post-execution verification failure must be preserved and investigated; it must not trigger an automatic corrective upgrade. The operational details are defined in `docs/SAFE_UPGRADE_RUNBOOK.md`.

## 12. Required V1-to-V1.1 upgrade test matrix

The Phase 1 suite must include a real proxy deployment and a real call to `upgradeToAndCall` from V1 to a UUPS-compatible V1.1 test implementation. The V1.1 implementation may expose only a harmless version/sentinel getter in addition to the V1 surface.

| Area | Required setup before upgrade | Required assertion after upgrade |
|---|---|---|
| Implementation switch | Deploy V1 behind a real `ERC1967Proxy`; deploy V1.1 | ERC-1967 implementation slot is V1.1 and the V1.1 sentinel succeeds through the proxy |
| Configuration | Initialize the first nine inputs and derived `collateralAsset` | Every economic/configuration getter is bit-for-bit unchanged |
| Explicit initial authority | Deploy the proxy from address A while passing distinct address B as `initialUpgradeAuthority_` | Active authority is B, pending authority is zero, B can upgrade, and A has no implicit upgrade permission |
| Invalid initial authority | Attempt proxy construction with `initialUpgradeAuthority_ == address(0)` | Constructor initialization reverts atomically with `InvalidUpgradeAuthority(address(0))`; no usable proxy is deployed |
| Authority | Establish active authority and a nonzero pending nomination | Active and pending authority state is unchanged; pending still cannot upgrade before acceptance |
| Index state | Create debt, advance time, and checkpoint | `borrowIndex` and `lastBorrowIndexUpdate` are exactly unchanged by the upgrade |
| Individual debt | Create scaled debt for at least two borrower addresses | Every tested `scaledDebtOf` entry is exactly unchanged |
| Total debt | Create nonzero aggregate scaled debt | `totalScaledDebt` is exactly unchanged |
| Individual collateral | Deposit collateral for at least two addresses | Every tested `collateralSharesOf` entry is exactly unchanged |
| Total collateral | Create nonzero aggregate collateral shares | `totalCollateralShares` is exactly unchanged |
| Individual liquidity | Deposit liquidity for at least two addresses | Every tested `liquidityBalanceOf` entry is exactly unchanged |
| Total liquidity | Create nonzero aggregate liquidity | `totalLiquidity` is exactly unchanged |
| Debt-asset custody | Leave debt-asset tokens at the proxy and record implementation balances | Exact proxy token balance and recorded implementation balance are unchanged; the workflow creates no implementation custody delta |
| Collateral custody | Leave any transient/direct collateral balance relevant to the fixture at the proxy and record implementation balances | Exact proxy balance and recorded implementation balance are unchanged; the workflow creates no implementation custody delta |
| Vault ownership | Make the proxy own nonzero ERC-4626 shares and record implementation share balances | Exact proxy vault-share balance and recorded implementation share balance are unchanged; the workflow creates no implementation custody delta |
| Approvals | Establish the pool-to-vault collateral approval through normal deposit behavior | Proxy approval remains unchanged; the workflow transfers no protocol approval to an implementation |
| Business behavior | Record representative views and complete a normal post-upgrade operation | Existing views and state transitions retain V1 behavior |

The preservation assertions must compare snapshots immediately before and immediately after the upgrade, before any optional post-upgrade call that intentionally changes state. The upgrade itself must use empty call data unless V1.1 has an explicitly specified reinitializer; the minimal V1.1 sentinel needs no reinitializer.

Additional negative tests are mandatory:

- an unrelated address cannot call `upgradeToAndCall`;
- when the proxy deployer differs from the explicitly configured initial authority, only the configured initial authority can upgrade;
- the proxy deployer has no implicit upgrade permission;
- a zero initial authority makes proxy deployment fail atomically with `InvalidUpgradeAuthority(address(0))`;
- a pending authority cannot upgrade before acceptance;
- the former authority cannot upgrade after an accepted transfer;
- a zero-address authority proposal reverts;
- a non-pending address cannot accept;
- a second `initialize(...)` call through the proxy reverts;
- `initialize(...)` on the implementation reverts;
- direct implementation calls to `upgradeToAndCall` fail the UUPS proxy-context check;
- upgrading to an address without code reverts;
- upgrading to a contract without `proxiableUUID()` reverts; and
- upgrading to a contract returning an invalid ERC-1822 UUID reverts.

## 13. Required invariants

The implementation and test suite must establish these invariants:

1. The implementation contract cannot be initialized at any version after construction.
2. Each proxy can be initialized exactly once at version 1.
3. The proxy is never left publicly accessible in an uninitialized state; initialization is atomic constructor data.
4. The initialized active authority equals the explicit `initialUpgradeAuthority_` value and is never derived from the proxy deployer or `msg.sender`.
5. The proxy deployer has no implicit upgrade permission when it differs from the configured active authority.
6. Only the active upgrade authority can authorize an upgrade.
7. A nominated pending authority has no upgrade permission before acceptance.
8. The active authority can never be the zero address, and no pending nomination can designate the zero address. A zero pending-storage value means no nomination, not a zero-address authority.
9. Renouncing upgrade authority is impossible because no renounce operation or zero-address transfer exists.
10. V1 legacy slots 0–17, including mapping seeds and values, remain identical across upgrades.
11. An upgrade alone does not change existing configuration or accounting state.
12. Deployment and upgrade execution do not move user tokens or vault shares to an implementation; unchanged unsolicited dust is recorded separately and no implementation custody delta is accepted.
13. The proxy remains the owner of its token balances, token approvals, and vault shares across upgrades.
14. Unauthorized upgrades revert without changing the implementation slot or any accounting state.
15. Upgrades to non-UUPS implementations or implementations reporting an invalid ERC-1822 UUID revert without changing the implementation slot or accounting state.
16. Authority proposal and acceptance change only the authority namespace and emit the specified authority event; they do not change legacy slots.
17. Existing accounting invariants continue to hold when all pool calls are made through the proxy.

## 14. Known pre-existing limitations

These limitations exist before upgradeability and must be documented and regression-tested where practical, but must not be fixed in Phase 1:

- **Utilization checkpointing:** liquidity deposits intentionally do not checkpoint the borrow index, and liquidity withdrawals also do not call `_updateBorrowIndex()`. A later debt mutation can therefore apply utilization based on the then-current liquidity to time elapsed since the prior checkpoint. In particular, a large intervening deposit may undercharge the preceding period. Phase 1 preserves these checkpoint rules.
- **Scaled-debt dust and rounding:** conversions between nominal and scaled debt use integer division. Partial borrow and repayment paths round down; sufficiently small amounts relative to the index can create zero-scaled changes or leave dust. Full repayment explicitly clears a user's entire scaled balance. Phase 1 does not change these rules.
- **Decimal compatibility:** oracle answers are normalized to WAD, but collateral-value and debt comparisons otherwise assume compatible token-unit conventions. The pool does not independently normalize collateral-token and debt-token decimals. Deployments must select compatible assets and feeds; Phase 1 adds no decimal adapter.
- **Liquidation health-factor behavior:** liquidation is allowed whenever the pre-liquidation health factor is below `1e18`, but the implementation does not require a partial liquidation to improve the post-liquidation health factor. With the current threshold, bonus, rounding, and caller-selected amount, a partial liquidation can fail to improve or can worsen that ratio. Phase 1 does not add a close factor or change this mathematics.
- **Residual bad debt:** collateral-capped liquidation can exhaust collateral while leaving scaled debt. The debt remains visible, but there is no terminal bad-debt resolution, reserve, or socialization regime.

The current `docs/protocol-spec.md` is a simplified conceptual document and does not always describe implemented behavior. It says liquidation must improve health factor or fully close a position, while `LendingPool.sol` does not enforce that postcondition. It also names an admin that sets parameters, while the current contract fixes those parameters at construction and has no economic setters. Those existing documentation/code mismatches do not authorize economic changes in Phase 1; this document controls the upgradeability phase and records the implementation behavior that must be preserved.

## 15. Acceptance criteria for complete Phase 1

Phase 1 implementation work is complete only when all of the following are true:

- the canonical pool is a new `LendingPool` implementation behind a real vendored OpenZeppelin 5.6.1 `ERC1967Proxy`;
- only `LendingPool` is upgradeable and `CollateralVault` remains non-upgradeable;
- the implementation constructor only disables initializers;
- the proxy initializes atomically with the ten-parameter initializer and initialization succeeds exactly once;
- all current constructor validation, assignment, and initial-value behavior is preserved;
- the first nine initializer parameters retain their existing types, order, validation, assignments, and economic meaning;
- the tenth initializer parameter explicitly configures a nonzero initial authority, the pending authority starts at the zero no-pending sentinel, and neither value is derived from `msg.sender`;
- tests prove that deployer and initial authority may differ, only the configured authority may upgrade, the deployer has no implicit permission, and a zero initial authority makes deployment fail atomically;
- the authority API, events, errors, two-step transfer, no-renounce rule, and ERC-7201 location match this document;
- `_authorizeUpgrade` accepts only the active authority;
- the exact legacy storage prefix in Section 7 remains unchanged;
- existing ABI, errors, business events, economics, rounding, and checkpoint behavior remain compatible except for the specified additions;
- baseline unit, fuzz, and invariant tests pass through the intended deployment model;
- the complete V1-to-V1.1 matrix and all negative upgrade tests in Section 12 pass;
- storage-layout output is captured before and after the implementation change and reviewed, with representative mapping values tested through the upgrade;
- deployment, preparation, and upgrade execution cause no implementation custody or approval transfer, unchanged unsolicited implementation dust is recorded separately, and the proxy retains canonical custody and approvals;
- deployment documentation identifies the proxy as canonical and prevents an uninitialized deployment;
- local tests and adversarial review pass before any public testnet deployment;
- the concluding public Sepolia portfolio deployment includes the non-upgradeable vault, V1 implementation, atomically initialized real proxy, clearly identified testnet-only dependencies where required, and compatible V1.1 implementation;
- the official Safe is configured as the sole initial upgrade authority with two distinct development EOA owners and a 2-of-2 threshold, while the deployer remains a separate non-authority;
- a representative lending flow and a real Safe-authorized V1-to-V1.1 upgrade execute on Sepolia through the proxy using deploy-and-prepare tooling, external Safe execution, and immediate read-only verification in a controlled state-freeze window;
- Foundry consumes no Safe-authority key or mnemonic and never broadcasts the authority action;
- distinct Safe, proxy, V1 implementation, and V1.1 implementation addresses, relevant dependency addresses, prepared calldata and fingerprint, and deployment/flow/Safe-execution transaction hashes are recorded;
- explorer source verification is completed where supported by available tooling, with any tooling limitation recorded; and
- no document or claim describes Phase 1 as production-ready or formally verified.

## 16. Future upgrade rules

Every future implementation version must begin from this specification and provide a version-specific design, storage diff, threat review, and upgrade test. It must retain the exact slots 0–17 prefix and every previously committed namespace. A field inside a namespace must not be reordered, deleted, or type-changed; additions require the same append-only discipline within that namespace.

Before authorization, reviewers must verify the new implementation has code, implements UUPS/ERC-1822 with the correct ERC-1967 implementation-slot UUID, preserves the proxy-context protections, and cannot initialize itself. Upgrade transactions must be prepared for the explicitly configured active authority, which need not be the original proxy deployer, and must use `upgradeToAndCall` with explicitly reviewed data. For the Sepolia demonstration, this means deploy-and-prepare by a separate implementation deployer, 2-of-2 execution by the external Safe, and independent read-only verification; it does not make Safe part of the core protocol implementation.

New reinitializers are allowed only when a future version needs new state initialization. Each must use a unique monotonically increasing version, be callable only through the proxy under explicitly documented authorization, initialize only newly introduced state, and be executed atomically with the upgrade when required. A version must never reuse an initializer or reset initialization state.

Future economic features—including parameter governance, supplier shares, reserves, close factors, decimal adapters, or bad-debt handling—require their own scoped specification and tests. They must not be smuggled into an infrastructure upgrade. Dependency upgrades likewise require source review of initialization, UUPS, proxy, and storage behavior rather than relying on semantic-version assumptions.
