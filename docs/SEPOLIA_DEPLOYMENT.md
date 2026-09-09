# Sepolia Deployment Evidence

## 1. Purpose and scope

This document records the public Ethereum Sepolia deployment of the repository's historical V1 lending system. It is intended as reproducible engineering evidence: it identifies the deployed contracts, authority model, deployment transactions, representative protocol interactions, and public read-only checks.

The deployment was validated through a representative on-chain protocol flow. This document does not claim comprehensive on-chain path coverage, an audit, or production readiness.

The ERC-1967 proxy listed below is the canonical pool, protocol-state, and custody address. It still points to the historical V1 implementation listed below, and the recorded representative flow belongs to V1. No public V1.1 or V1.2 upgrade has occurred. V1.2 exists only as an implemented, tested, migration-reviewed local candidate with Safe preparation and verification tooling; deploying it and executing its atomic migration remain future explicitly authorized operations.

## 2. Public deployment summary

| Item | Public value |
| --- | --- |
| Network | Ethereum Sepolia |
| Chain ID | `11155111` |
| Canonical LendingPool | [`0x4Ba81845c2E130013EF2Be36e220cA1166E70873`](https://sepolia.etherscan.io/address/0x4Ba81845c2E130013EF2Be36e220cA1166E70873) (ERC1967 proxy) |
| Active implementation | Historical V1 at [`0x4f5c7dC968602b54519F515576FeC936405CB940`](https://sepolia.etherscan.io/address/0x4f5c7dC968602b54519F515576FeC936405CB940) |
| Deployer and demo actor | [`0x9f33C581581BC878f638541DB2b75e117A36BEfD`](https://sepolia.etherscan.io/address/0x9f33C581581BC878f638541DB2b75e117A36BEfD) |
| Upgrade authority | [`0xe6E0B9B815666bE6B3dbbf441f678C9618196760`](https://sepolia.etherscan.io/address/0xe6E0B9B815666bE6B3dbbf441f678C9618196760) (Safe 1.4.1, 2-of-2) |
| Pending upgrade authority | `0x0000000000000000000000000000000000000000` |
| Oracle | [Chainlink Sepolia ETH / USD](https://sepolia.etherscan.io/address/0x694AA1769357215DE4FAC081bf1f309aDC325306), `8` decimals |

The deployer/demo actor is distinct from the upgrade authority. The Safe was reviewed with the following two owners, a threshold of 2 of 2, and no enabled modules at deployment review:

- [`0x5cAD4b69A0E985C904Cb4900aEAeb35E1A23540C`](https://sepolia.etherscan.io/address/0x5cAD4b69A0E985C904Cb4900aEAeb35E1A23540C)
- [`0x72c9990BC964A92F0b12BBcCBc25158a670c0461`](https://sepolia.etherscan.io/address/0x72c9990BC964A92F0b12BBcCBc25158a670c0461)

## 3. Architecture and authority model

Users and integrations interact with the LendingPool at proxy address `0x4Ba81845c2E130013EF2Be36e220cA1166E70873`. The ERC1967 proxy holds protocol state, sdUSD custody, pool accounting, CollateralVault shares, and pool-to-vault approvals. It delegates execution to the V1 implementation at `0x4f5c7dC968602b54519F515576FeC936405CB940`; the implementation is a code target, not a user-facing pool or custody address.

The separately deployed `CollateralVault` is an ERC-4626 vault and is not upgradeable. It holds sdETH while the proxy owns the corresponding vault shares and records each user's collateral-share claim. The pool uses the external Chainlink Sepolia ETH / USD feed to value the ETH-like demo collateral in USD-like debt-asset units.

The LendingPool is UUPS-upgradeable. Its active upgrade authority remains the Safe at `0xe6E0B9B815666bE6B3dbbf441f678C9618196760`; its pending upgrade authority is the zero address. Under the recorded Safe configuration, an upgrade requires both owners to approve a Safe transaction. This separates deployment and demo activity from upgrade authorization. No such public upgrade transaction is recorded: the proxy remains on V1.

## 4. Contract addresses

| Contract | Role | Sepolia address and source |
| --- | --- | --- |
| sdETH | Fixed-supply, 18-decimal demo collateral asset | [`0x8B54b640d7400feB0FC656107663c522F32aebfD`](https://sepolia.etherscan.io/address/0x8B54b640d7400feB0FC656107663c522F32aebfD#code) |
| sdUSD | Fixed-supply, 18-decimal demo debt/liquidity asset | [`0x72F2D0363ad4dEde02B666091Ec8961862cfa316`](https://sepolia.etherscan.io/address/0x72F2D0363ad4dEde02B666091Ec8961862cfa316#code) |
| CollateralVault | Non-upgradeable ERC-4626 sdETH vault | [`0xE3A2DB1b1031121A297d78e072F401e175076a15`](https://sepolia.etherscan.io/address/0xE3A2DB1b1031121A297d78e072F401e175076a15#code) |
| LendingPool V1 implementation | UUPS implementation/code target | [`0x4f5c7dC968602b54519F515576FeC936405CB940`](https://sepolia.etherscan.io/address/0x4f5c7dC968602b54519F515576FeC936405CB940#code) |
| ERC1967 proxy / LendingPool | Canonical user-facing protocol and state address | [`0x4Ba81845c2E130013EF2Be36e220cA1166E70873`](https://sepolia.etherscan.io/address/0x4Ba81845c2E130013EF2Be36e220cA1166E70873#code) |

## 5. Deployment transactions

| Phase | Deployment | Sepolia transaction |
| --- | --- | --- |
| 1 | sdETH | [`0xf64a989f9d7ae5862f2cc443c9a21907f36b650df46a11633b0a2f9ebd82c238`](https://sepolia.etherscan.io/tx/0xf64a989f9d7ae5862f2cc443c9a21907f36b650df46a11633b0a2f9ebd82c238) |
| 1 | sdUSD | [`0x06a1cbf8a14147929fa790f19c8da6e35db2f7525c590d42598496adb5f752e9`](https://sepolia.etherscan.io/tx/0x06a1cbf8a14147929fa790f19c8da6e35db2f7525c590d42598496adb5f752e9) |
| 2 | CollateralVault | [`0x790c27fd6397e8272863c8dedf12a1eef1d4c97e0a88b4f2592cc3bb03a3b551`](https://sepolia.etherscan.io/tx/0x790c27fd6397e8272863c8dedf12a1eef1d4c97e0a88b4f2592cc3bb03a3b551) |
| 2 | LendingPool V1 implementation | [`0xac807bd466a4ee5dcf8fe6ab7a1e4ca2773b5986a75a46862da4e7d9cbe95794`](https://sepolia.etherscan.io/tx/0xac807bd466a4ee5dcf8fe6ab7a1e4ca2773b5986a75a46862da4e7d9cbe95794) |
| 2 | ERC1967 proxy deployment and atomic initialization | [`0x8dad810577c3eefce0f2c3778318d32ac31eac7eccbe26821199bc8723bcf8f1`](https://sepolia.etherscan.io/tx/0x8dad810577c3eefce0f2c3778318d32ac31eac7eccbe26821199bc8723bcf8f1) |

## 6. Representative on-chain protocol flow

The deployer/demo actor executed the following sequence against the canonical proxy:

| Step | Action | Sepolia transaction |
| --- | --- | --- |
| 1 | Approve 10,000 sdUSD for liquidity | [`0xcb78a9f44ef211d3739421c5e673dc7409e23139ec90be070b016e4011f2d186`](https://sepolia.etherscan.io/tx/0xcb78a9f44ef211d3739421c5e673dc7409e23139ec90be070b016e4011f2d186) |
| 2 | Deposit 10,000 sdUSD liquidity | [`0x962bdf8d194aa7869fa9bf88e855195ada30e94433b0b4e6965708ddab137e1a`](https://sepolia.etherscan.io/tx/0x962bdf8d194aa7869fa9bf88e855195ada30e94433b0b4e6965708ddab137e1a) |
| 3 | Approve 1 sdETH as collateral | [`0xaa493f303b3735bf5c6010afbdc99ff0ab9114514e728431b4a073c106502c9b`](https://sepolia.etherscan.io/tx/0xaa493f303b3735bf5c6010afbdc99ff0ab9114514e728431b4a073c106502c9b) |
| 4 | Deposit 1 sdETH collateral | [`0x1ee4f3f686d785e61a9ff6119654e1391249f772766f47fe193e26960d9d867f`](https://sepolia.etherscan.io/tx/0x1ee4f3f686d785e61a9ff6119654e1391249f772766f47fe193e26960d9d867f) |
| 5 | Borrow 1,000 sdUSD | [`0xdad7d6708a422e6beb1a0be983e53aac4c813702049a586d9448f9a283d7f799`](https://sepolia.etherscan.io/tx/0xdad7d6708a422e6beb1a0be983e53aac4c813702049a586d9448f9a283d7f799) |
| 6 | Approve 250 sdUSD for repayment | [`0x68da378d062b92e6c06e54e4be13d537c74e4de546d3419b56fc111db11ea4b8`](https://sepolia.etherscan.io/tx/0x68da378d062b92e6c06e54e4be13d537c74e4de546d3419b56fc111db11ea4b8) |
| 7 | Repay 250 sdUSD | [`0x9c34148049b6b0d6f594f80c4a67df581d8760f04e44ccc7042d7e300ea96042`](https://sepolia.etherscan.io/tx/0x9c34148049b6b0d6f594f80c4a67df581d8760f04e44ccc7042d7e300ea96042) |

This historical V1 sequence demonstrates token approvals, liquidity accounting, ERC-4626 collateral custody and share accounting, oracle-constrained borrowing, indexed debt creation, and partial repayment. It is not evidence that V1.1 or V1.2 was installed.

## 7. Post-flow public state

The verified post-flow state is:

| State item | Result |
| --- | --- |
| Recorded pool liquidity (`totalLiquidity`) | 10,000 sdUSD |
| Demo actor liquidity balance (`liquidityBalanceOf`) | 10,000 sdUSD |
| Demo actor collateral shares | 1 share |
| CollateralVault assets / total share supply | 1 sdETH / 1 share |
| Demo actor current debt | Approximately 750 sdUSD remains live |
| Active upgrade authority | 2-of-2 Safe at `0xe6E0B9B815666bE6B3dbbf441f678C9618196760` |
| Pending upgrade authority | `0x0000000000000000000000000000000000000000` |

`totalLiquidity` and `liquidityBalanceOf` are recorded deposit-accounting values; they are not claims that the proxy's immediately available sdUSD token balance is also 10,000 after borrowing. The exact value returned by `debtBalanceOf` can rise above the post-repayment amount as time passes because V1 debt accrues interest. Leaving this debt live is intentional public protocol-state evidence, not an incomplete cleanup.

## 8. Source verification status

All five contracts in the contract-address table have verified source code on Sepolia Etherscan. Etherscan identifies the canonical pool contract as an `ERC1967Proxy` and automatically associates it with the V1 implementation at `0x4f5c7dC968602b54519F515576FeC936405CB940`.

No manual proxy-association write was submitted or is claimed here.

## 9. Reproduction and inspection commands

The following read-only commands use only public on-chain addresses. Run them with `cast` configured for Ethereum Sepolia in the caller's environment; endpoint configuration is deliberately not embedded here. Integer token amounts are returned in 18-decimal raw units unless otherwise noted.

Confirm the network and core wiring:

```bash
cast chain-id
cast call 0x4Ba81845c2E130013EF2Be36e220cA1166E70873 "vault()(address)"
cast call 0x4Ba81845c2E130013EF2Be36e220cA1166E70873 "collateralAsset()(address)"
cast call 0x4Ba81845c2E130013EF2Be36e220cA1166E70873 "debtAsset()(address)"
cast call 0x4Ba81845c2E130013EF2Be36e220cA1166E70873 "priceFeed()(address)"
cast storage 0x4Ba81845c2E130013EF2Be36e220cA1166E70873 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
```

Inspect the representative actor's accounting and the vault state:

```bash
cast call 0x4Ba81845c2E130013EF2Be36e220cA1166E70873 "totalLiquidity()(uint256)"
cast call 0x4Ba81845c2E130013EF2Be36e220cA1166E70873 "liquidityBalanceOf(address)(uint256)" 0x9f33C581581BC878f638541DB2b75e117A36BEfD
cast call 0x4Ba81845c2E130013EF2Be36e220cA1166E70873 "collateralSharesOf(address)(uint256)" 0x9f33C581581BC878f638541DB2b75e117A36BEfD
cast call 0x4Ba81845c2E130013EF2Be36e220cA1166E70873 "debtBalanceOf(address)(uint256)" 0x9f33C581581BC878f638541DB2b75e117A36BEfD
cast call 0xE3A2DB1b1031121A297d78e072F401e175076a15 "totalAssets()(uint256)"
cast call 0xE3A2DB1b1031121A297d78e072F401e175076a15 "totalSupply()(uint256)"
```

Inspect authority, asset metadata, and oracle identity:

```bash
cast call 0x4Ba81845c2E130013EF2Be36e220cA1166E70873 "upgradeAuthority()(address)"
cast call 0x4Ba81845c2E130013EF2Be36e220cA1166E70873 "pendingUpgradeAuthority()(address)"
cast call 0x8B54b640d7400feB0FC656107663c522F32aebfD "symbol()(string)"
cast call 0x8B54b640d7400feB0FC656107663c522F32aebfD "decimals()(uint8)"
cast call 0x72F2D0363ad4dEde02B666091Ec8961862cfa316 "symbol()(string)"
cast call 0x72F2D0363ad4dEde02B666091Ec8961862cfa316 "decimals()(uint8)"
cast call 0x694AA1769357215DE4FAC081bf1f309aDC325306 "description()(string)"
cast call 0x694AA1769357215DE4FAC081bf1f309aDC325306 "decimals()(uint8)"
```

The first command should return chain ID `11155111`. The ERC-1967 storage word should end in the implementation address `4f5c7dc968602b54519f515576fec936405cb940`; address casing is not significant in the padded storage value. The live debt read can differ from exactly 750 sdUSD because interest accrues.

## 10. Limitations and non-claims

- This is a testnet deployment only.
- sdETH and sdUSD are fixed-supply demonstration assets, not production assets.
- The ETH/USD feed semantics apply to the ETH-like demo collateral; they do not establish a general oracle model for arbitrary collateral.
- No public V1-to-V1.1 upgrade has been executed.
- No public V1/V1.1-to-V1.2 implementation deployment or proxy upgrade has been executed; V1.2 remains a local candidate.
- V1.2 improves checkpoint consistency, compounding precision, explicit rounding, and numerical-domain enforcement without invalidating this recorded V1 deployment or flow as historical evidence.
- The recorded Safe has a 2-of-2 threshold and two distinct owner EOAs, but both EOAs are controlled by the same repository author/operator. Two owner-account approvals are technically required, demonstrating Safe transaction mechanics, threshold enforcement, and key/account separation; this setup does not provide independent-person, independent-organization, or production-governance separation.
- Safe ownership does not eliminate signer compromise, key-management, transaction-review, or operational risk.
- This evidence is not an audit or a production-readiness claim.
- No liquidation is claimed to have been publicly executed.
- The representative flow does not claim that every protocol path was exercised on-chain.
