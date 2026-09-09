# Safe-controlled V1.2 Upgrade Runbook

## 1. Current status and purpose

This runbook documents the tooling and review sequence for a possible future V1/V1.1-to-V1.2 UUPS upgrade. It does not authorize one.

The canonical Sepolia proxy is live and still delegates to the historical V1 implementation. Its recorded flow is V1 evidence. No public V1.1 or V1.2 upgrade has occurred. V1.2 implementation, atomic migration, preparation tooling, verifier, and tests are completed locally; public candidate deployment and Safe execution remain future explicitly authorized operations.

This is testnet operational guidance, not production governance or incident-response guidance. It makes no audit, formal-verification, or production-readiness claim.

## 2. Roles and authority boundary

- **Implementation deployer:** broadcasts only direct typed construction of a new `LendingPoolV1_2`. It is not the pool upgrade authority.
- **Safe owner accounts:** two distinct EOAs that must each approve the external Safe transaction under the recorded 2-of-2 threshold.
- **Safe:** the contract configured as the pool's active upgrade authority. It alone calls the canonical proxy.
- **Canonical proxy:** permanent pool, state, direct debt custody, and vault-share owner; it is the Safe transaction target.
- **V1.2 candidate:** authenticated implementation code target, never a pool or custody address.
- **Preparation script:** `script/UpgradeLendingPoolV1_2.s.sol`; deploys the candidate, snapshots evidence, and constructs canonical calldata.
- **Verifier:** `script/VerifyLendingPoolV1_2Upgrade.s.sol`; performs read-only state and accounting verification after execution.

Foundry does not receive, control, or impersonate the Safe. The scripts do not authenticate the Safe owner set, threshold, nonce, EIP-712 `safeTxHash`, confirmations, signatures, execution receipt, or logs. Those are external Safe-review and evidence responsibilities. Never place a private key or mnemonic in the repository or in a Solidity environment variable.

The recorded demonstration Safe's two owner EOAs are both controlled by the same repository author/operator. Requiring both distinct accounts to approve demonstrates Safe transaction mechanics, threshold enforcement, externalized upgrade authority, and key/account separation; it does not demonstrate independent human signers, organizationally independent governance, or production-governance separation. In a real deployment, governance should instead use independently controlled signers with appropriate operational security, transaction-review, continuity, and recovery procedures.

## 3. Required atomic payload

The canonical Safe transaction is:

| Field | Required value |
| --- | --- |
| `to` | Canonical `LendingPool` proxy |
| `value` | `0` |
| `data` | Canonical ABI encoding of `upgradeToAndCall(newV1_2, abi.encodeCall(migrateToV1_2, ()))` |
| Safe operation | `CALL` (`0`), never `DELEGATECALL` |

The outer selector is `upgradeToAndCall(address,bytes)` (`0x4f1ef286`) and the inner calldata is exactly the four-byte `migrateToV1_2()` selector with canonical ABI padding. The preparation script rejects a different target, nonzero value, wrong implementation, wrong selector, empty inner data, trailing data, noncanonical offset, length, or padding.

A plain implementation replacement without the migration calldata is not an accepted path. V1.2 accounting remains inactive until initializer version 2 is reached. The atomic call ensures that a failed migration also rolls back the implementation-slot update.

## 4. Preparation inputs

The preparation script reads:

| Variable | Meaning |
| --- | --- |
| `EXPECTED_CHAIN_ID` | Expected chain ID; `11155111` for Sepolia |
| `LENDING_POOL_PROXY` | Canonical proxy and prepared transaction target |
| `EXPECTED_CURRENT_IMPLEMENTATION` | V1 or V1.1 implementation currently in the ERC-1967 slot |
| `EXPECTED_UPGRADE_AUTHORITY` | Contract expected to be the active authority; the recorded public system uses its Safe |
| `EXPECTED_PENDING_UPGRADE_AUTHORITY` | Expected pending authority, normally the zero sentinel |
| `TRACKED_ACCOUNT_SET_IS_COMPLETE` | Whether the supplied accounts are claimed to cover all three mappings |
| `TRACKED_ACCOUNTS` | Comma-separated, nonzero addresses in strictly increasing numeric order |

The account list must be derived from authenticated deployment and interaction evidence. Mapping storage is not enumerable. If completeness is true, tracked `scaledDebtOf`, `collateralSharesOf`, and `liquidityBalanceOf` sums must equal all corresponding aggregate totals. If false, the evidence covers only the supplied leaves.

## 5. Preparation workflow

Do not run this public-chain command without a separate explicit deployment authorization. A local rehearsal can call the script's non-broadcast `prepare` path through its tests. For an authorized public preparation, use an externally configured Foundry account:

```bash
EXPECTED_CHAIN_ID="11155111" \
LENDING_POOL_PROXY="<CANONICAL_PROXY>" \
EXPECTED_CURRENT_IMPLEMENTATION="<ACTIVE_V1_OR_V1_1_IMPLEMENTATION>" \
EXPECTED_UPGRADE_AUTHORITY="<SAFE_ADDRESS>" \
EXPECTED_PENDING_UPGRADE_AUTHORITY="0x0000000000000000000000000000000000000000" \
TRACKED_ACCOUNT_SET_IS_COMPLETE="<true-or-false>" \
TRACKED_ACCOUNTS="<SORTED_COMMA_SEPARATED_ADDRESSES>" \
forge script script/UpgradeLendingPoolV1_2.s.sol:UpgradeLendingPoolV1_2 \
  --rpc-url "<SEPOLIA_RPC_URL_OR_ALIAS>" \
  --account "<EXTERNAL_IMPLEMENTATION_DEPLOYER_ACCOUNT>" \
  --broadcast \
  -vvvv
```

The only broadcast operation inside `run()` is `new LendingPoolV1_2()`. Before construction, the script snapshots the predicted deployment address's incidental token and vault-share balances. After construction, the broadcast boundary closes and all remaining work is read-only. The script directly authenticates the constructed candidate rather than accepting an arbitrary candidate address.

Preparation validates:

- chain, proxy code, expected current implementation code and implementation-slot identity;
- current implementation ERC-1822 UUID;
- active and pending upgrade authorities, including code at the configured contract authority;
- proxy initializer version 1 and non-initializing state;
- candidate code, distinct addresses, V1.2 version, correct UUID, and constructor-locked initializers;
- the exact post-construction runtime `extcodehash`; and
- absence of candidate-deployment changes to proxy evidence or recorded implementation balances.

The runtime hash is captured from the exact deployed address. UUPS embeds an immutable `__self`, so hashes from different deployment addresses are not assumed identical even when produced from the same source.

## 6. Preparation evidence

The state fingerprint is domain-separated and binds:

- chain ID, proxy, old and new implementation addresses, and the new runtime code hash;
- raw protocol slots 0–17 and the Initializable namespace word;
- active and pending authority;
- every dependency, risk parameter, and rate parameter;
- stored index, timestamp, aggregate collateral shares, liquidity, and scaled debt;
- proxy direct collateral and debt balances, proxy vault shares, vault total assets and supply, and vault collateral balance;
- the canonical tracked-account snapshots and completeness flag; and
- old and new implementation incidental token and vault-share balances at preparation.

The prepared record also contains:

- the exact target, value, and calldata;
- the pre-upgrade state hash;
- a payload fingerprint binding chain, expected authority, target, value, and calldata;
- a commitment to the ordered tracked-account list; and
- a preparation-attestation digest over the identities, candidate hash, commitments, state hash, and payload.

Preserve the full ABI-encoded pre-upgrade state and every printed field. Preserve the preparation-attestation digest independently from that evidence bundle—for example, in a separately controlled review record—and later supply that exact trusted value to the verifier.

The digest is not a signature, Safe transaction hash, candidate deployment receipt, registry record, or on-chain attestation. It detects evidence or payload substitution only if the original externally preserved digest remains trusted. If an actor replaces both the evidence bundle and the digest supplied as its trust root, a purely local verifier cannot distinguish the replacement. Stronger provenance would require an external signature, immutable registry, verified receipt, or other independent authority.

## 7. Fresh preflight and state freeze

The preparation hash is evidence, not a proxy transaction guard. State may change after preparation. Immediately before Safe confirmation and execution:

1. establish a controlled window with no protocol actions, authority changes, custody changes, or representative flows;
2. rerun the read-only preflight against the exact expected chain, proxy, implementation, authority, and tracked accounts;
3. compare current state with the preserved preparation evidence;
4. confirm the candidate runtime code hash still matches; and
5. abandon the transaction if any relevant state or identity changed.

If state changes, discard the stale Safe proposal and evidence for execution purposes, rerun deployment/preparation as required by the reviewed procedure, and restart both-owner review with the new exact payload and trust root.

## 8. Safe review and execution

For the recorded demonstration, the operator must complete the following review for both owner accounts before providing the two required approvals. In a real deployment, each independently controlled signer should perform the review under its governance procedures:

- Sepolia chain ID `11155111`, the recorded Safe address, owner set, and 2-of-2 threshold;
- exact proxy `to`, zero `value`, and byte-for-byte prepared `data`;
- `CALL` operation value `0`;
- exact candidate address and authenticated runtime hash;
- outer and inner selectors and decoded arguments;
- expected current implementation, active authority, and pending-authority sentinel;
- exact applicable Safe nonce and all other Safe transaction fields;
- independently derived cryptographic `safeTxHash`; and
- each owner's confirmation of that exact hash, operation, and nonce.

Do not confuse a Safe Transaction Service proposal identifier with the cryptographic `safeTxHash`. After execution, record the separate Ethereum execution transaction hash and obtain the V1.2 activation timestamp from authenticated execution/block evidence. The local verifier checks state, not receipts or logs.

## 9. Verification inputs

The read-only verifier reads:

| Variable | Meaning |
| --- | --- |
| `EXPECTED_CHAIN_ID` | Expected chain ID |
| `LENDING_POOL_PROXY` | Canonical proxy |
| `EXPECTED_OLD_IMPLEMENTATION` | Implementation active during preparation |
| `EXPECTED_NEW_IMPLEMENTATION` | Prepared V1.2 candidate |
| `EXPECTED_NEW_IMPLEMENTATION_CODE_HASH` | Candidate runtime hash recorded at preparation |
| `EXPECTED_UPGRADE_AUTHORITY` | Expected unchanged active authority |
| `EXPECTED_PENDING_UPGRADE_AUTHORITY` | Expected unchanged pending authority |
| `TRACKED_ACCOUNT_SET_IS_COMPLETE` | Preparation completeness flag |
| `TRACKED_ACCOUNTS` | Exact ordered preparation account list |
| `EXPECTED_V1_2_ACTIVATION_TIMESTAMP` | Timestamp of atomic migration execution |
| `EXPECTED_PRE_UPGRADE_STATE_HASH` | Preparation state hash |
| `EXPECTED_TRACKED_ACCOUNT_COMMITMENT` | Preparation list commitment |
| `PREPARED_TARGET` | Exact prepared proxy target |
| `PREPARED_VALUE` | Exact prepared value, zero |
| `PREPARED_CALLDATA` | Exact prepared atomic migration calldata |
| `EXPECTED_PREPARED_PAYLOAD_FINGERPRINT` | Preparation payload fingerprint |
| `TRUSTED_PREPARATION_ATTESTATION_DIGEST` | Independently preserved trust root |
| `PRE_UPGRADE_STATE_ABI` | Full ABI-encoded preparation state |

Run without `--broadcast` and without a broadcaster account:

```bash
EXPECTED_CHAIN_ID="11155111" \
LENDING_POOL_PROXY="<CANONICAL_PROXY>" \
EXPECTED_OLD_IMPLEMENTATION="<PREPARATION_OLD_IMPLEMENTATION>" \
EXPECTED_NEW_IMPLEMENTATION="<PREPARED_V1_2_IMPLEMENTATION>" \
EXPECTED_NEW_IMPLEMENTATION_CODE_HASH="<PREPARED_CODE_HASH>" \
EXPECTED_UPGRADE_AUTHORITY="<SAFE_ADDRESS>" \
EXPECTED_PENDING_UPGRADE_AUTHORITY="0x0000000000000000000000000000000000000000" \
TRACKED_ACCOUNT_SET_IS_COMPLETE="<PREPARATION_VALUE>" \
TRACKED_ACCOUNTS="<EXACT_PREPARATION_LIST>" \
EXPECTED_V1_2_ACTIVATION_TIMESTAMP="<EXECUTION_BLOCK_TIMESTAMP>" \
EXPECTED_PRE_UPGRADE_STATE_HASH="<PREPARATION_STATE_HASH>" \
EXPECTED_TRACKED_ACCOUNT_COMMITMENT="<PREPARATION_ACCOUNT_COMMITMENT>" \
PREPARED_TARGET="<PREPARATION_TARGET>" \
PREPARED_VALUE="0" \
PREPARED_CALLDATA="<PREPARATION_CALLDATA>" \
EXPECTED_PREPARED_PAYLOAD_FINGERPRINT="<PREPARATION_PAYLOAD_FINGERPRINT>" \
TRUSTED_PREPARATION_ATTESTATION_DIGEST="<INDEPENDENTLY_PRESERVED_DIGEST>" \
PRE_UPGRADE_STATE_ABI="<PREPARATION_STATE_ABI>" \
forge script script/VerifyLendingPoolV1_2Upgrade.s.sol:VerifyLendingPoolV1_2Upgrade \
  --rpc-url "<SEPOLIA_RPC_URL_OR_ALIAS>" \
  -vvvv
```

## 10. Verification verdict

The verifier fails unless it confirms:

- the trusted preparation digest, state hash, tracked-account commitment, and canonical payload all agree;
- the proxy implementation slot contains the expected candidate and no longer contains the old implementation;
- the candidate runtime hash, UUID, and proxy-reported version are V1.2;
- Initializable is at version 2 and is not initializing;
- authority, configuration, frozen slots other than index/timestamp, aggregates, tracked leaves, and authoritative custody are unchanged;
- the stored boundary index equals an independent calculation using the exact historical formula through the activation timestamp;
- the stored checkpoint timestamp equals that activation timestamp; and
- the current utilization-derived rate and RAY-accrued current index match independent calculations after activation.

The migration intentionally changes the implementation slot, initializer version, stored borrow index, and last-index timestamp. Existing scaled debt is preserved; the verifier does not expect a scaled-balance rewrite.

## 11. Incidental implementation balances

Construction-time continuity remains relevant: the preparation flow records balances at the predicted candidate address and rejects changes caused during typed deployment/preparation. This helps show that deployment itself did not move protocol assets.

After preparation, anyone may send tokens or vault shares directly to either implementation. Those balances are incidental and are not protocol custody. Post-verification reports preparation and observed values plus exact per-asset change flags, but implementation dust does not change the core verdict.

Proxy and vault custody remain authoritative. Any unexpected proxy debt balance, proxy direct collateral balance, proxy vault-share balance, vault assets, vault supply, or vault collateral balance fails verification. Never weaken those checks because an implementation balance appears harmless.

## 12. Fail-closed and rollback procedure

- **Preparation failure:** no payload is accepted; preserve the error and diagnose it.
- **State change before execution:** do not execute stale calldata; discard the stale proposal and restart preparation and owner review.
- **Migration revert:** the EVM rolls back the implementation slot and all migration writes. Confirm the old implementation remains active before taking any further action.
- **Inactive empty-data install:** do not treat it as successful. Accounting calls fail closed; recovery is a separately authorized action, not the planned workflow.
- **Verification failure:** do not report the upgrade as verified. Preserve preparation output, independent digest, Safe confirmations, execution transaction, verifier logs, and explorer evidence. Inspect every mismatch and intervening transaction.
- **Response:** never perform an automatic corrective upgrade. Any response requires its own design, preparation, review, and Safe authorization.

## 13. Public evidence record

The historical V1 addresses and transactions remain canonical in [SEPOLIA_DEPLOYMENT.md](SEPOLIA_DEPLOYMENT.md). Do not overwrite that record with local rehearsal values.

For any future public V1.2 operation, leave every field `PENDING` until independently evidenced:

| Future V1.2 evidence | Status |
| --- | --- |
| Reviewed commit and build identity | `PENDING` |
| V1.2 implementation address, deployment transaction, and runtime code hash | `PENDING` |
| Preparation state ABI/hash, payload fingerprint, account commitment, and independently preserved attestation digest | `PENDING` |
| Exact target, value, calldata, Safe operation, and nonce | `PENDING` |
| Exact cryptographic `safeTxHash` and both owner confirmations | `PENDING` |
| Executed Ethereum transaction hash and activation timestamp | `PENDING` |
| Read-only verifier output and incidental-balance report | `PENDING` |
| Explorer source-verification links, if completed | `PENDING` |

Until those future fields are completed from authentic public evidence, the correct public status remains: canonical Sepolia V1 is live; V1.2 is a local upgrade candidate and has not been publicly deployed or installed.
