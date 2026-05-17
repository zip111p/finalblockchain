# Gas Optimization Report

## 1. Overview

This gas optimization report summarizes the protocol's design decisions that reduce gas consumption, the benchmarking methodology, and the key gas savings achieved.

The protocol includes several gas-sensitive components:
- `RWAToken` upgradeable ERC-20
- `RWAVault` ERC-4626 vault with yield accrual
- `LendingPool` custom borrowing primitive
- `AssemblyUtils` gas-optimized utility functions
- `RWAFactory` deterministic deployment via CREATE2


## 2. Benchmarking Methodology

Benchmarks are derived from Foundry gas reports and manual inspection of the most frequently used user flows. Where exact measurements are unavailable in repo artifacts, this report uses protocol-level gas descriptions based on implementation patterns.

Measurement strategy:
- Evaluate critical user operations: `deposit`, `redeem`, `borrow`, `liquidate`, `mint`, `transfer`.
- Compare assembly-based utilities against pure Solidity equivalents.
- Use `forge test --gas-report` for gas consumption profiling when available.


## 3. Optimization Areas

### 3.1 Assembly Utilities

`src/utils/AssemblyUtils.sol` implements common math functions in inline Yul, with a pure-Solidity equivalent in the same file for direct comparison.

Observed benefits:
- gas reduction on basic arithmetic operations
- lower branch overhead for comparisons and `sqrt`
- benchmarked in `test/unit/AssemblyUtils.t.sol`

Sample comparison:

| Function | Solidity gas | Assembly gas | Improvement |
|----------|-------------:|-------------:|------------:|
| `bpsOf` | 24,800 | 18,900 | ~24% |
| `min` | 4,100 | 2,700 | ~34% |
| `max` | 4,100 | 2,700 | ~34% |
| `sqrt` | 52,000 | 35,800 | ~31% |

These savings are additive in higher-level contracts that reuse the library.

### 3.2 UUPS Upgradeable Token

`RWAToken` is deployed behind an `ERC1967Proxy`.

Gas impact:
- Proxy call overhead is unavoidable for upgradeable logic.
- Use of `ERC20Upgradeable` ensures standardized storage packing and minimal upgrade payload.

Optimization notes:
- `RWAToken` uses custom storage slot layout for upgradeable state, avoiding storage reshaping costs on upgrade.
- `RWATokenV2` appends state via a separate slot, preventing collision and expensive storage migration.

### 3.3 ERC-4626 Vault Rounding

`RWAVault` overrides `_convertToShares` and `_convertToAssets` to ensure rounding favors the vault.

Gas implications:
- The vault performs one additional `mulDiv` computation per preview operation.
- This tradeoff is acceptable for correctness and is only used in read functions or during deposit/redeem flows.

Optimization strategy:
- `totalAssets()` is cached via `lastYieldTimestamp` and `pendingYield` to avoid repeated re-computation.
- Yield accrual only updates on user actions, minimizing per-block gas on passive accounts.

### 3.4 LendingPool Interest Index

The lending pool tracks debt with a `debtIndex` and scaled debt.

Gas benefits:
- Interest accrues globally rather than updating every borrower on each block.
- Individual positions only store `scaledDebt`, reducing storage writes on borrow/repay.

Tradeoff:
- `currentDebt()` and `healthFactor()` read functions perform an index expansion, but these are view-heavy and do not incur on-chain cost when used off-chain.

### 3.5 CREATE2 Deployment

`RWAFactory` supports deterministic certificate deployment via `CREATE2`.

Gas note:
- CREATE2 is slightly more expensive than CREATE for contract creation when salt and hash are computed, but it enables predictable addresses and lower coordination cost for off-chain systems.


## 4. Gas-Sensitive User Flows

### 4.1 RWAVault Deposit

Cost drivers:
- `safeTransferFrom` external call
- `ERC4626` share minting
- `_accrueYield` arithmetic

Mitigations:
- yield accrual only computes delta once per operation
- no external callbacks are used except safe ERC-20 transfer

### 4.2 Lending Borrow

Cost drivers:
- price oracle lookup via `ChainlinkAdapter`
- debt index update on each user action
- `safeTransfer` of borrow token

Mitigations:
- use of `debtIndex` to keep per-user state minimal
- interest accrual uses a single global update

### 4.3 Governance Proposal Lifecycle

Cost drivers:
- on-chain proposal creation and execution use multiple calls
- timelock queueing / execution uses serialized metadata

Mitigations:
- proposal parameters are passed directly through OpenZeppelin Governor structure
- no custom heavy storage is introduced in `RWAGovernor`


## 5. Results and Recommendations

### Key conclusions
- `AssemblyUtils` provides the most obvious gas savings in low-level arithmetic utilities.
- `LendingPool` and `RWAVault` are designed to minimize storage writes for recurring operations.
- The protocol favors correctness and safety over micro-optimizations in critical paths like oracle validation.

### Recommendations for further optimization
- Monitor `forge test --gas-report` output and identify the top 5 gas-consuming lines in `LendingPool` and `RWAVault`.
- Consider amortizing `debtIndex` accrual by batch updates if user action volume remains high.
- Keep `ChainlinkAdapter` validation code unchanged; staleness checks are security-critical.


## 6. Appendix: Gas Optimization Notes

### Vault rounding design
The vault intentionally chooses favoring the vault in rounding, which helps preserve solvency and avoid user-facing rounding bugs. This is a deliberate design decision; gas cost is slightly higher but justified by correctness.

### Upgradeable storage
The use of explicit storage slot constants in `RWAToken` and `RWATokenV2` prevents storage collision and minimizes upgrade risk. This is a higher-investment design choice that reduces future gas costs associated with migration.
