# Safe-controlled Sepolia upgrade runbook

## 1. Purpose and scope

This runbook defines the future public Sepolia portfolio demonstration of a state-preserving UUPS upgrade from `LendingPool` V1 to V1.1. An official Safe configured with a 2-of-2 threshold is the sole upgrade authority for the `LendingPool` proxy. Repository tooling deploys and validates the contracts, prepares the exact upgrade transaction, and independently verifies the result; the Safe owners review, confirm, and execute the upgrade outside Foundry.

This is an educational testnet and portfolio demonstration. It is not production governance guidance, an incident-response procedure, or evidence of production readiness or formal verification. The repository does not implement Safe, a multisig, governance, or a timelock.

## 2. Roles and trust boundaries

- **Implementation deployer:** a development EOA that broadcasts the V1.1 implementation deployment. It may also deploy the initial V1 system, but it has no upgrade authority.
- **Safe owner A:** the first development EOA configured as an owner of the official Safe.
- **Safe owner B:** a distinct second development EOA configured as an owner of the official Safe.
- **Safe 2-of-2:** the official Safe whose address is supplied as `INITIAL_UPGRADE_AUTHORITY`. It is the only active `LendingPool` upgrade authority, and both owners must confirm an upgrade transaction.
- **LendingPool proxy:** the canonical pool and custody address. Safe calls this address to execute `upgradeToAndCall(address,bytes)`.
- **Current V1 implementation:** the implementation referenced by the proxy before the upgrade.
- **Prepared V1.1 implementation:** the separately deployed, UUPS-compatible target that adds no mutable storage, preserves the complete V1 storage layout, and is validated by the preparation script.
- **Read-only verifier:** `VerifyLendingPoolV1_1Upgrade.s.sol`, run independently after Safe execution without `--broadcast`.

The implementation deployer and Safe must be distinct. Deployment does not confer upgrade authority. Foundry never receives, controls, or impersonates the Safe authority: it prepares calldata for external Safe execution but does not execute the upgrade. No Safe-owner private key, broadcaster private key, or mnemonic belongs in the repository or in Solidity environment variables. Broadcasters must use external Foundry account configuration, and Safe owners must confirm through the official Safe interface or independently approved Safe tooling.

## 3. Architecture and sequence

The recorded public V1 deployment and representative flow completed steps 1-4, with canonical evidence maintained in [SEPOLIA_DEPLOYMENT.md](SEPOLIA_DEPLOYMENT.md). The future public V1-to-V1.1 upgrade begins at step 5. For a separately reviewed independent V1 redeployment, repeat the complete sequence rather than reusing the recorded evidence:

1. Create an official Safe on Sepolia, configure Safe owner A and Safe owner B, and confirm the threshold is 2-of-2.
2. Deploy the V1 vault and implementation, then deploy the proxy with atomic initialization, passing the Safe address as `INITIAL_UPGRADE_AUTHORITY`.
3. Confirm that the deployment broadcaster and the Safe address are distinct and that only the Safe is the active authority.
4. Optionally execute a controlled representative V1 protocol flow through the proxy, retaining any state intended for preservation evidence.
5. Run the V1.1 deploy-and-prepare script. It may broadcast only the V1.1 implementation deployment; it must not execute the proxy upgrade.
6. Preserve the reported pre-upgrade state hash with the prepared target, value, calldata, and implementation address.
7. Independently review the target, zero value, calldata, `CALL` operation (`0`), exact Safe nonce, chain, proxy, old and new implementations, active authority, and pending-authority sentinel.
8. Submit the exact reviewed transaction to the Safe and record its exact cryptographic Safe transaction hash (`safeTxHash`) separately from any later Ethereum transaction hash.
9. Obtain and record confirmations from both Safe owners for that exact `safeTxHash`, operation, and nonce.
10. Execute the confirmed transaction through the Safe and separately record the executed Ethereum transaction hash.
11. Run the independent read-only verifier immediately after execution.
12. Record the public evidence listed in Section 9.

```text
Deployer/Foundry        V1.1 impl.          LendingPool proxy      Safe 2-of-2          Verifier
       |                    |                       |                    |                  |
       |-- deploy V1 + atomically initialized proxy>|                    |                  |
       |-- deploy V1.1 -->|                       |                    |                  |
       |-- prep read/check ->|                       |                    |                  |
       |-- prep read/check ------------------------->|                    |                  |
       |   produce target/value/calldata/state hash |                    |                  |
       |                    |                       |                    | owners confirm   |
       |                    |                       |<-- call ------------|                  |
       |                    |<-- impl ref = V1.1 ----|                    |                  |
       |                    |<--------------------------------------- read impl/custody --|
       |                    |                       |<------------ read proxy/custody ----|
```

`impl ref = V1.1` is the proxy's ERC-1967 implementation-reference update. The arrows are role boundaries, not a claim that Foundry submits to Safe. Transfer the prepared transaction into the official Safe workflow only after independent review.

## 4. Environment variables

These are the exact Solidity environment variables read by the scripts. Addresses and configuration values are public inputs; none is a private key, mnemonic, password, or Safe-owner credential. RPC and external account selection are command-line concerns, not Solidity environment variables.

### V1 deployment: `DeployLendingPoolV1.s.sol`

| Variable | Meaning |
|---|---|
| `COLLATERAL_ASSET` | Address of the selected Sepolia collateral ERC-20. |
| `DEBT_ASSET` | Address of the selected Sepolia debt ERC-20. |
| `PRICE_FEED` | Address of the selected Sepolia price-feed dependency. |
| `COLLATERAL_VAULT_NAME` | Name for the newly deployed non-upgradeable vault. |
| `COLLATERAL_VAULT_SYMBOL` | Symbol for the newly deployed non-upgradeable vault. |
| `MAX_PRICE_STALENESS` | Maximum accepted oracle staleness in seconds. |
| `LTV_BPS` | Loan-to-value setting in basis points. |
| `LIQUIDATION_THRESHOLD_BPS` | Liquidation threshold in basis points. |
| `LIQUIDATION_BONUS_BPS` | Liquidation bonus in basis points. |
| `BASE_BORROW_RATE` | Base borrow-rate input in WAD units. |
| `BORROW_RATE_SLOPE` | Borrow-rate slope input in WAD units. |
| `INITIAL_UPGRADE_AUTHORITY` | Official Sepolia Safe address; this must not be the deployer address. |
| `EXPECTED_CHAIN_ID` | Expected Sepolia chain ID, `11155111`. |

### V1.1 deployment and preparation: `UpgradeLendingPoolV1_1.s.sol`

| Variable | Meaning |
|---|---|
| `LENDING_POOL_PROXY` | Canonical V1 proxy and Safe transaction target. |
| `EXPECTED_V1_IMPLEMENTATION` | V1 implementation expected in the proxy's ERC-1967 slot before preparation. |
| `EXPECTED_UPGRADE_AUTHORITY` | Official Safe address expected as the active authority. |
| `EXPECTED_PENDING_UPGRADE_AUTHORITY` | Expected pending authority; use the zero-address sentinel when no transfer is pending. |
| `EXPECTED_CHAIN_ID` | Expected Sepolia chain ID, `11155111`. |

### Post-upgrade verification: `VerifyLendingPoolV1_1Upgrade.s.sol`

| Variable | Meaning |
|---|---|
| `EXPECTED_CHAIN_ID` | Expected Sepolia chain ID, `11155111`. |
| `LENDING_POOL_PROXY` | Canonical proxy expected to have been upgraded. |
| `EXPECTED_OLD_IMPLEMENTATION` | V1 implementation expected to be inactive after the upgrade. |
| `EXPECTED_NEW_IMPLEMENTATION` | Prepared V1.1 implementation expected in the ERC-1967 slot. |
| `EXPECTED_UPGRADE_AUTHORITY` | Official Safe address expected to remain active. |
| `EXPECTED_PENDING_UPGRADE_AUTHORITY` | Expected pending authority, normally the zero-address sentinel. |
| `EXPECTED_PRE_UPGRADE_STATE_HASH` | State hash emitted by the matching preparation run. |

### Educational dependency deployment: `DeploySepoliaDemoDependencies.s.sol`

| Variable | Meaning |
|---|---|
| `EXPECTED_CHAIN_ID` | Must be Sepolia chain ID, `11155111`. |
| `DEMO_TOKEN_HOLDER` | Nonzero holder receiving each token's complete fixed initial supply. |
| `COLLATERAL_INITIAL_SUPPLY` | Nonzero initial raw supply for 18-decimal `sdETH`. |
| `DEBT_INITIAL_SUPPLY` | Nonzero initial raw supply for 18-decimal `sdUSD`. |
| `PRICE_FEED` | Explicit external Chainlink ETH/USD proxy address; verify immediately before broadcast. |
| `MAX_PRICE_STALENESS` | Nonzero maximum accepted feed age in seconds. |

### Educational representative flow: `RunSepoliaDemoFlow.s.sol`

Run this only after the dependency and V1 deployment verification records have been reviewed. It uses one configured external demo actor for operational simplicity; that actor must be distinct from the official Safe and has no upgrade authority. This is an educational single-actor smoke flow, not evidence of multi-party economic independence, production readiness, or formal verification.

| Variable | Meaning |
|---|---|
| `EXPECTED_CHAIN_ID` | Must be Sepolia chain ID, `11155111`. |
| `LENDING_POOL_PROXY` | Canonical deployed LendingPool proxy. |
| `COLLATERAL_VAULT` | Deployed non-upgradeable CollateralVault. |
| `COLLATERAL_TOKEN` | Deployed 18-decimal `Sepolia Demo Ether` (`sdETH`). |
| `DEBT_TOKEN` | Deployed 18-decimal `Sepolia Demo USD` (`sdUSD`). |
| `PRICE_FEED` | Explicit external official Chainlink Sepolia ETH/USD proxy, 8 decimals. |
| `EXPECTED_SAFE_AUTHORITY` | Official 2-of-2 Safe expected to be the sole active upgrade authority. |
| `DEMO_ACTOR` | External Foundry-account address that performs every user operation; never the Safe. |
| `LIQUIDITY_DEPOSIT_AMOUNT` | Exact `sdUSD` amount deposited as pool liquidity. |
| `COLLATERAL_DEPOSIT_AMOUNT` | Exact `sdETH` amount deposited as collateral. |
| `BORROW_AMOUNT` | Exact `sdUSD` amount borrowed. |
| `PARTIAL_REPAY_AMOUNT` | Nonzero `sdUSD` repayment, strictly less than `BORROW_AMOUNT`. |

For any future independently reviewed run, the script first performs a read-only preflight and dry-run. A human must make the separate, explicit decision to add `--broadcast`; no command in this runbook authorizes broadcast by default. When authorized, use the configured actor's external Foundry account and record seven separate Ethereum transaction hashes, in this exact order: debt-token approval; liquidity deposit; collateral-token approval; collateral deposit; borrow; fresh debt-token repayment approval; and nonzero partial repayment. Record the script output, all seven transaction hashes, configured amounts, actor/pool/vault/token/feed/Safe addresses, before/after token balances, liquidity position, collateral shares, scaled debt, and confirmation that the authority and pending-authority sentinel remained unchanged. The flow never deploys, transfers demo tokens directly, withdraws, liquidates, or invokes an authority/upgrade operation.

### Asset dependency preflight

#### Educational Sepolia demo dependencies

`SepoliaDemoERC20` is the repository-controlled educational dependency used for the recorded public Sepolia V1 demonstration and may be used only for a separately reviewed educational redeployment. It is instantiated as `Sepolia Demo Ether` (`sdETH`) for ETH-like collateral and `Sepolia Demo USD` (`sdUSD`) for USD-like debt. Both tokens have 18 decimals, a fixed supply minted once at construction, standard exact-transfer OpenZeppelin ERC-20 behavior, and no rebasing or privileged token mechanism. Neither token represents production token infrastructure.

The debt/collateral price dependency remains an external official Chainlink Sepolia ETH/USD AggregatorV3 proxy. It supplies USD per one ETH and is not deployed or controlled by this repository. Immediately before any dependency broadcast, independently verify the exact feed address against the official Chainlink directory and its Sepolia on-chain runtime state; do not replace the explicit `PRICE_FEED` deployment input with a repository constant. With 18-decimal `sdETH`, an ETH/USD price normalized to WAD, and 18-decimal `sdUSD`, `collateralRaw * priceWad / 1e18` produces `sdUSD` raw units.

The recorded V1 deployment passed the official Safe directly as `INITIAL_UPGRADE_AUTHORITY` during atomic proxy initialization. The active authority was therefore the Safe, the pending authority was zero, and the deployer was never temporarily granted protocol upgrade authority or transferred out of that role afterward. Any later independent deployment must preserve and independently verify this property.

The canonical Phase 1 asset and callback boundary is defined in [Asset and callback boundary](../README.md#asset-and-callback-boundary). The deployment operator and dependency reviewers must complete this checklist before setting `COLLATERAL_ASSET` or `DEBT_ASSET` and before approving the V1 deployment:

- [ ] confirm the network is Sepolia (`11155111`) and independently resolve each exact token address from the reviewed deployment record;
- [ ] record whether each token is a repository-controlled testnet mock or an external dependency, and verify its name and symbol when those metadata functions are available;
- [ ] fetch the deployed runtime bytecode at each address, record its hash, and match it to verified source or a reproducible repository build and deployment workflow;
- [ ] read and record each token's decimals from the selected Sepolia contract;
- [ ] establish with source/bytecode review and controlled transfer evidence that `transfer` and `transferFrom` debit the sender and credit the recipient by exactly the requested amount, with no fee, tax, burn, reflection, or recipient-side deduction;
- [ ] cover both protocol directions for the debt asset (account to pool for liquidity deposits, repayments, and liquidations; pool to account for borrowing and liquidity withdrawals);
- [ ] cover all protocol and vault directions for the collateral asset (account to pool, pool to vault, vault to pool or liquidator, and pool to withdrawing account);
- [ ] establish with source/bytecode review and balance observations across the controlled demonstration window that neither token rebases nor changes balances autonomously;
- [ ] verify the price feed's base/quote meaning and decimals, then demonstrate that `collateralRawAmount * priceWad / 1e18` produces debt-asset raw units for representative and boundary values; and
- [ ] have the deployment operator and dependency reviewers sign off on the evidence record before broadcast.

The deployment script's code-length and `balanceOf` probes do not prove these properties. Successful ERC-20 calls and matching decimals are also insufficient on their own. If any identity, bytecode, behavior, decimals, or unit evidence is missing or inconsistent, do not deploy with that dependency.

Verified public Sepolia dependency and deployment evidence now exists in [SEPOLIA_DEPLOYMENT.md](SEPOLIA_DEPLOYMENT.md). It records the repository-controlled fixed-supply demo assets sdETH and sdUSD, including their public addresses, metadata roles, verified-source links, deployment transactions, and representative flow. This evidence applies only to the recorded deployment; any later redeployment must independently repeat dependency, bytecode, decimal, unit, oracle, and behavioral checks rather than blindly reusing the recorded evidence.

## 5. Commands

Replace every angle-bracketed placeholder before running a command. `<SEPOLIA_RPC_URL_OR_ALIAS>` identifies the Sepolia endpoint. `<EXTERNAL_FOUNDRY_DEPLOYER_ACCOUNT>` is an account name from Foundry's external default keystore, not a key or mnemonic. These templates do not authorize a real run until the dependencies, values, and controlled window have been reviewed.

### Clean local preflight

```bash
forge clean
forge build
forge test -vv
forge fmt --check
```

### Deploy V1 with atomic proxy initialization and the Safe as authority

```bash
COLLATERAL_ASSET="<COLLATERAL_ASSET_ADDRESS>" \
DEBT_ASSET="<DEBT_ASSET_ADDRESS>" \
PRICE_FEED="<PRICE_FEED_ADDRESS>" \
COLLATERAL_VAULT_NAME="<COLLATERAL_VAULT_NAME>" \
COLLATERAL_VAULT_SYMBOL="<COLLATERAL_VAULT_SYMBOL>" \
MAX_PRICE_STALENESS="<MAX_PRICE_STALENESS_SECONDS>" \
LTV_BPS="<LTV_BPS>" \
LIQUIDATION_THRESHOLD_BPS="<LIQUIDATION_THRESHOLD_BPS>" \
LIQUIDATION_BONUS_BPS="<LIQUIDATION_BONUS_BPS>" \
BASE_BORROW_RATE="<BASE_BORROW_RATE_WAD>" \
BORROW_RATE_SLOPE="<BORROW_RATE_SLOPE_WAD>" \
INITIAL_UPGRADE_AUTHORITY="<OFFICIAL_SAFE_ADDRESS>" \
EXPECTED_CHAIN_ID="11155111" \
forge script script/DeployLendingPoolV1.s.sol:DeployLendingPoolV1 \
  --rpc-url "<SEPOLIA_RPC_URL_OR_ALIAS>" \
  --account "<EXTERNAL_FOUNDRY_DEPLOYER_ACCOUNT>" \
  --broadcast \
  -vvvv
```

### Deploy V1.1 and prepare the Safe transaction

```bash
LENDING_POOL_PROXY="<LENDING_POOL_PROXY_ADDRESS>" \
EXPECTED_V1_IMPLEMENTATION="<V1_IMPLEMENTATION_ADDRESS>" \
EXPECTED_UPGRADE_AUTHORITY="<OFFICIAL_SAFE_ADDRESS>" \
EXPECTED_PENDING_UPGRADE_AUTHORITY="0x0000000000000000000000000000000000000000" \
EXPECTED_CHAIN_ID="11155111" \
forge script script/UpgradeLendingPoolV1_1.s.sol:UpgradeLendingPoolV1_1 \
  --rpc-url "<SEPOLIA_RPC_URL_OR_ALIAS>" \
  --account "<EXTERNAL_FOUNDRY_DEPLOYER_ACCOUNT>" \
  --broadcast \
  -vvvv
```

This command broadcasts only the V1.1 implementation deployment. Its output is the proxy, expected current implementation, new implementation, expected upgrade authority, prepared Safe target, zero value, exact `upgradeToAndCall` calldata, and pre-upgrade state hash. Foundry does not execute the upgrade, submit a Safe proposal, impersonate the Safe, or supply or control its operation or nonce. Safe operation and nonce selection intentionally remain part of the external Safe workflow.

### Verify immediately after Safe execution

```bash
EXPECTED_CHAIN_ID="11155111" \
LENDING_POOL_PROXY="<LENDING_POOL_PROXY_ADDRESS>" \
EXPECTED_OLD_IMPLEMENTATION="<V1_IMPLEMENTATION_ADDRESS>" \
EXPECTED_NEW_IMPLEMENTATION="<PREPARED_V1_1_IMPLEMENTATION_ADDRESS>" \
EXPECTED_UPGRADE_AUTHORITY="<OFFICIAL_SAFE_ADDRESS>" \
EXPECTED_PENDING_UPGRADE_AUTHORITY="0x0000000000000000000000000000000000000000" \
EXPECTED_PRE_UPGRADE_STATE_HASH="<PRE_UPGRADE_STATE_HASH>" \
forge script script/VerifyLendingPoolV1_1Upgrade.s.sol:VerifyLendingPoolV1_1Upgrade \
  --rpc-url "<SEPOLIA_RPC_URL_OR_ALIAS>" \
  -vvvv
```

The verifier command intentionally has no `--broadcast` and consumes no broadcaster or Safe-owner account.

## 6. Safe transaction review checklist

Before either Safe owner confirms, both reviewers must independently verify:

- [ ] the connected network is Sepolia and the chain ID is `11155111`;
- [ ] the submitting Safe address is the recorded official Safe and its threshold is 2-of-2;
- [ ] `to` exactly equals the canonical `LendingPool` proxy and the preparation output's target;
- [ ] `value` is exactly `0`;
- [ ] `data` exactly equals the complete prepared `upgradeToAndCall` calldata, byte for byte;
- [ ] `operation` is `CALL`, with numeric operation value `0`;
- [ ] the exact Safe nonce is recorded and matches both the Safe transaction proposed for confirmation and the Safe's applicable on-chain/current transaction state for execution;
- [ ] both owner A and owner B have reviewed the exact `CALL (0)` operation and exact nonce before either owner confirms;
- [ ] the exact cryptographic Safe transaction hash (`safeTxHash`) is independently derived for the reviewed Safe address and chain, `to`, `value`, `data`, `operation = CALL (0)`, exact nonce, and every other Safe transaction field that participates in the hash; and
- [ ] both owner A and owner B confirm that exact `safeTxHash`, not merely a proposal or UI identifier;
- [ ] the calldata selector is `upgradeToAndCall(address,bytes)` (`0x4f1ef286`);
- [ ] the first argument exactly equals the prepared V1.1 implementation;
- [ ] the second argument is empty bytes;
- [ ] the current ERC-1967 implementation is the expected V1 implementation;
- [ ] the active upgrade authority is the Safe;
- [ ] the pending upgrade authority equals the expected sentinel, normally the zero address;
- [ ] the prepared pre-upgrade state hash is recorded with the transaction evidence; and
- [ ] the preparation checks validated the V1 and V1.1 implementation UUIDs and the V1.1 version.

`DELEGATECALL` (numeric operation value `1`) is prohibited: it would execute the calldata in the Safe's context rather than call the canonical `LendingPool` proxy. Any operation mismatch invalidates the proposal.

Preparation intentionally does not fetch, guess, supply, or control the Safe nonce because proposal, confirmation, and execution remain external to the repository tooling. If the reviewed nonce becomes stale or conflicts with the Safe's applicable current transaction state, do not silently substitute another nonce after owner review. Regenerate the external Safe proposal with the applicable nonce, derive and record its new exact `safeTxHash`, and restart both-owner review before either owner confirms.

A Safe Transaction Service proposal ID or UI identifier may be recorded as optional supplemental evidence, but it is not the cryptographic `safeTxHash` and must never replace it.

Any mismatch invalidates the review. Do not edit decoded arguments, operation, or nonce silently; discard the mismatched Safe proposal and create a new external proposal from the reviewed preparation output and applicable Safe nonce.

### Final execution-approval checkpoint

Immediately before approving execution, both owners must complete this checkpoint against the exact Safe proposal. No pre-execution item below may remain `PENDING`; Section 9's upgrade-specific `PENDING` values describe the future public V1-to-V1.1 upgrade only.

- [ ] `to`, `value`, and `data` match the reviewed preparation output exactly;
- [ ] operation name `CALL` and numeric operation value `0` are recorded and unchanged;
- [ ] the exact Safe nonce is recorded, unchanged from both-owner review, and still matches the Safe's applicable on-chain/current transaction state;
- [ ] the exact `safeTxHash` derived from every reviewed hash-participating Safe transaction field is recorded;
- [ ] owner A's confirmation and owner B's confirmation for this exact `safeTxHash`, operation, and nonce are separately recorded; and
- [ ] both owners approve execution of this exact confirmed proposal.

After execution, record the executed Ethereum transaction hash in its separate evidence field immediately. Do not use the `safeTxHash`, a Safe Transaction Service proposal ID, or a UI identifier as a substitute, and do not report the ceremony complete while the executed Ethereum transaction hash remains `PENDING`.

## 7. Fingerprint semantics

Preparation and verification are separate processes on opposite sides of an externally executed Safe transaction. A cross-run fingerprint is therefore required to bind the independently observed post-upgrade state to the state and exact implementation pair recorded during preparation.

The v2 fingerprint is domain-separated and covers:

- chain ID, proxy address, and the expected old and new implementation addresses;
- the raw values of legacy slots 0 through 17;
- active and pending upgrade-authority addresses;
- configuration: price feed, vault, debt asset, collateral asset, maximum price staleness, LTV, liquidation threshold, liquidation bonus, base borrow rate, and borrow-rate slope;
- accounting totals: borrow index, last index-update timestamp, total collateral shares, total liquidity, and total scaled debt;
- custody observations: direct proxy collateral-asset balance, proxy debt-asset balance, proxy vault-share balance, vault total assets, vault total supply, and the vault's collateral-asset balance; and
- for both the old and new implementation addresses, collateral-asset balance, debt-asset balance, and vault-share balance.

The proxy's ERC-1967 implementation-slot value is intentionally excluded because that slot must change from V1 to V1.1. The expected old and new implementation addresses are included instead, and the verifier separately requires the slot to contain the expected V1.1 address.

Unchanged unsolicited token or vault-share dust at either implementation address and unchanged direct proxy collateral dust are included and accepted; the tooling does not require those balances to be zero. Changes to any fingerprinted custody or protocol-state value, including any direct proxy collateral delta during the controlled window, cause a mismatch. A legitimate protocol action between preparation and verification also changes the relevant state and causes a mismatch, which is why Section 8 requires a controlled state freeze.

Raw mapping seed slots do not enumerate or cryptographically prove every mapping entry. Representative borrower, collateral-provider, and liquidity-provider positions are covered separately by the integration tests. The fingerprint is operational evidence for this controlled demonstration, not formal verification or a proof of all possible state.

## 8. State-freeze procedure

Establish a controlled window that begins immediately before V1.1 preparation and ends only after Safe execution and successful read-only verification. During that window, do not perform representative flows, protocol actions, authority transfers, custody movements, or other transactions that can change the fingerprinted state. Review and execute promptly enough to make intervening activity easy to audit.

If protocol state changes before Safe execution:

1. Do not execute the stale calldata or rely on its stale state evidence.
2. Discard the stale prepared Safe transaction.
3. Rerun the deploy-and-prepare command.
4. Use only the newly prepared implementation address, target, value, calldata, and state hash.
5. Restart both-owner review from the beginning.

If verification fails after Safe execution:

1. Do not report the upgrade as successfully verified.
2. Preserve the preparation output, verifier logs, Safe confirmations, execution transaction, and relevant explorer evidence.
3. Inspect the ERC-1967 implementation slot, active and pending authorities, proxy and vault state, implementation custody, and every intervening transaction.
4. Do not perform an automatic corrective upgrade. Diagnose and review any proposed response as a separate operation.

## 9. Public evidence checklist

### Recorded public V1 deployment

The public Sepolia V1 deployment and representative on-chain flow are complete. Canonical addresses, transaction hashes, authority state, source-verification status, and flow evidence are maintained in [SEPOLIA_DEPLOYMENT.md](SEPOLIA_DEPLOYMENT.md). Do not duplicate or fork that canonical record in this runbook.

### Future V1 redeployment template

This is a blank template for a new, independently reviewed V1 deployment. Every field starts `PENDING` for that new run. These placeholders do not describe the completed recorded deployment, must not be filled by copying its evidence, and are not evidence. Do not invent a missing address, hash, result, link, or report.

| New V1 deployment evidence | New-run value |
|---|---|
| Commit SHA | `PENDING` |
| Sepolia chain ID | `PENDING` |
| Safe address and 2-of-2 threshold | `PENDING` |
| Safe owner A address | `PENDING` |
| Safe owner B address | `PENDING` |
| Collateral dependency: role, Sepolia address, name, symbol, decimals, and repository-controlled mock or external classification | `PENDING` |
| Collateral dependency: deployed runtime bytecode hash and source/build/deployment identity evidence | `PENDING` |
| Collateral dependency: exact-transfer evidence for account → pool → vault and vault → pool/liquidator or pool → account paths | `PENDING` |
| Collateral dependency: non-rebasing and no-autonomous-balance-change evidence | `PENDING` |
| Debt dependency: role, Sepolia address, name, symbol, decimals, and repository-controlled mock or external classification | `PENDING` |
| Debt dependency: deployed runtime bytecode hash and source/build/deployment identity evidence | `PENDING` |
| Debt dependency: exact-transfer evidence for account → pool and pool → account paths | `PENDING` |
| Debt dependency: non-rebasing and no-autonomous-balance-change evidence | `PENDING` |
| Collateral/debt decimals and oracle/token raw-unit compatibility calculation | `PENDING` |
| Price-feed address | `PENDING` |
| CollateralVault address | `PENDING` |
| V1 implementation address | `PENDING` |
| LendingPool proxy address | `PENDING` |
| V1 deployment transaction | `PENDING` |
| Representative V1 flow transaction hash or hashes | `PENDING` |

### Future public V1-to-V1.1 upgrade evidence

No public V1-to-V1.1 upgrade has occurred. Every upgrade-specific field below remains `PENDING` until the separate Safe preparation, two-owner review, execution, verification, and evidence process is completed. Placeholders are not evidence and must not be replaced with invented values.

| Future V1-to-V1.1 upgrade evidence | Pending value |
|---|---|
| V1.1 implementation address | `PENDING` |
| V1.1 implementation-deployment transaction | `PENDING` |
| Prepared target, value, and calldata | `PENDING` |
| Safe operation name (`CALL`) | `PENDING` |
| Safe operation numeric value (`0`) | `PENDING` |
| Exact Safe nonce | `PENDING` |
| Pre-upgrade state hash | `PENDING` |
| Exact Safe transaction hash (`safeTxHash`) | `PENDING` |
| Safe owner A confirmation for the exact `safeTxHash`, operation, and nonce | `PENDING` |
| Safe owner B confirmation for the exact `safeTxHash`, operation, and nonce | `PENDING` |
| Executed Ethereum transaction hash | `PENDING` |
| Read-only verifier output | `PENDING` |
| Contract-verification links | `PENDING` |
| Final full-suite result | `PENDING` |
| Final audit report reference | `PENDING` |

## 10. Known limitations

- This is a testnet and portfolio demonstration, not a production deployment or governance recommendation.
- Both distinct Safe owner accounts are controlled by one repository author; the 2-of-2 ceremony demonstrates mechanics, not organizational independence.
- There is no timelock, governance module, or repository-implemented multisig.
- There is no production incident-response process.
- No production-readiness, completed-final-audit, or formal-verification claim is made.
- The fingerprint has the scope and mapping limitations described in Section 7 and cannot prove every mapping entry or all possible state.
- Phase 1 preserves the existing narrow V1 economics, including its documented pre-existing limitations; V1.1 adds no mutable storage, preserves the complete V1 storage layout, and is behaviorally minimal.
