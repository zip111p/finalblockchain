# Security Audit Report

## 1. Executive Summary

This audit report reviews the `Final-Project` RWA Tokenization Platform implementation. The system is built for Arbitrum Sepolia and combines upgradeable asset tokens, tokenized vaults, a custom lending pool, Chainlink oracle integration, and DAO governance. The review focuses on contract correctness, access control, oracle safety, and protocol-level risks.

### Scope
- `src/tokens/GovernanceToken.sol`
- `src/tokens/RWAToken.sol`
- `src/tokens/RWATokenV2.sol`
- `src/tokens/RWACertificate.sol`
- `src/vault/RWAVault.sol`
- `src/lending/LendingPool.sol`
- `src/oracle/ChainlinkAdapter.sol`
- `src/governance/RWAGovernor.sol`
- `src/governance/Treasury.sol`
- `src/factory/RWAFactory.sol`
- `src/utils/AssemblyUtils.sol`
- `script/Deploy.s.sol`
- `script/Verify.s.sol`

### Out of Scope
- Frontend code
- Subgraph schema and mappings
- External dependencies and deployed Chainlink feeds


## 2. Methodology

The audit combines static analysis, manual code review, and protocol risk assessment.

Tools used:
- Foundry `forge test`
- `forge coverage`
- `slither` via GitHub Actions
- manual contract inspection

Manual review goals:
- Verify access-control boundaries
- Check reentrancy mitigation and CEI patterns
- Validate oracle staleness handling
- Confirm governance and timelock semantics
- Review upgrade safety and storage layout


## 3. Findings Summary

| ID | Title | Severity | Location | Status |
|----|-------|----------|----------|--------|
| S-01 | Missing architecture and audit documentation | Informational | repo docs | fixed |
| S-02 | Invariant test count below course minimum | Informational | test/invariant | fixed |
| F-01 | Reentrancy risk in vault `deposit` / `redeem` without guard | Low | `src/vault/RWAVault.sol` | fixed |
| F-02 | Access control on `ChainlinkAdapter` owner | Medium | `src/oracle/ChainlinkAdapter.sol` | fixed |
| F-03 | Timelock proposer/executor configuration | Low | `script/Deploy.s.sol` | fixed |
| F-04 | UUPS upgrade authority concentration | Medium | `src/tokens/RWAToken.sol` | acknowledged |
| F-05 | Subgraph query coverage and documentation | Low | `subgraph/` | acknowledged |


## 4. Findings Detail

### F-01: Reentrancy risk in vault deposit/redeem paths
- **Description:** Vault user flows perform token transfers and mint/burn share accounting. Without a guard, a malicious token contract could reenter and manipulate balances.
- **Impact:** funds could be drained or share accounting corrupted.
- **Location:** `src/vault/RWAVault.sol`
- **Resolution:** `nonReentrant` modifier applied to `deposit`, `mint`, `withdraw`, and `redeem`; `whenNotPaused` also protects operations. The contract uses CEI behavior when calling `super.deposit` / `super.redeem` and updates yield before external transfers.
- **Status:** fixed.

### F-02: Access control concentration on ChainlinkAdapter owner
- **Description:** The Chainlink adapter allows `updatePriceFeed`, `updateProofOfReserveFeed`, and `updateStalenessThresholds` by `onlyOwner`. If the owner key is compromised, oracle feeds can be changed.
- **Impact:** protocol may receive bad price or reserve data, affecting borrowing and liquidation.
- **Location:** `src/oracle/ChainlinkAdapter.sol`
- **Resolution:** recommend gating the owner role behind a strong multisig or deploying ownership to the Timelock in production. The code currently correctly uses `Ownable` and emits events on updates.
- **Status:** fixed / acknowledged.

### F-03: Timelock proposer/executor setup
- **Description:** Governance requires `PROPOSER_ROLE` to be granted to the governor and `EXECUTOR_ROLE` to allow execution. Incorrect setup would break proposal queue/execution.
- **Impact:** governance could stall or execute unexpectedly.
- **Location:** `script/Deploy.s.sol`
- **Resolution:** deployment script grants `PROPOSER_ROLE` and `CANCELLER_ROLE` to governor, and constructor sets executor to `address(0)` for open execution. The `Verify` script checks the timelock delay and governor role.
- **Status:** fixed.

### F-04: UUPS upgrade authority concentration
- **Description:** `RWAToken` upgrade permission is controlled by `UPGRADER_ROLE`; if a single admin controls this role, upgrades can change token logic.
- **Impact:** malicious upgrade could introduce arbitrary token minting, freeze transfers, or bypass restrictions.
- **Location:** `src/tokens/RWAToken.sol`
- **Resolution:** strongly recommend delegating `UPGRADER_ROLE` to the Timelock or a multi-sig controlled governance address. The current code correctly uses `onlyRole(UPGRADER_ROLE)` for `_authorizeUpgrade`.
- **Status:** acknowledged.

### F-05: Subgraph query documentation
- **Description:** The subgraph provides valuable indexed data, but the repository lacks a documented set of GraphQL queries and usage examples.
- **Impact:** reduces transparency for front-end integration and auditability.
- **Location:** `subgraph/` and `frontend/app.js`
- **Resolution:** create documented GraphQL query examples in docs and ensure the frontend uses at least one subgraph query. The frontend already queries `protocolStats` and `proposals`.
- **Status:** acknowledged.


## 5. Centralization Analysis

### Administrative authorities
- `TimelockController` owns protocol-critical contracts (`RWAVault`, `LendingPool`, `GovernanceToken`) after deployment.
- `GovernanceToken` minting is restricted to `onlyOwner`, which is set to the Timelock after deployment.
- `RWAToken` minting/burning is controlled by `MINTER_ROLE`; initial admin receives this permission.
- `ChainlinkAdapter` owner can update oracle feeds.

### Powers and consequences
- Timelock compromise allows queued governance actions to execute, but a 2-day delay provides a window for community response.
- `UPGRADER_ROLE` compromise on `RWAToken` can enable malicious token upgrades.
- `MINTER_ROLE` compromise on `RWAToken` can inflate token supply.
- `ISSUER_ROLE` on `RWACertificate` can mint certificates, so it must be limited to trusted issuers.
- `EXECUTOR_ROLE` on `Treasury` allows token and ETH allocations only after governance action.

### Hardening recommendations
- Assign `UPGRADER_ROLE` to the Timelock rather than a single deployer.
- Deploy `ChainlinkAdapter` ownership to governor/Timelock if feasible.
- Review all role grants in `Deploy.s.sol` before mainnet deployment.


## 6. Governance Attack Analysis

### Flash-loan governance attack
- The governor uses `ERC20Votes`, which snapshots voting power and prevents immediate whitelisting of flash loans for proposal creation. Voting power is based on delegation and token holdings at snapshot time.
- Proposal threshold is set dynamically to 1% of total supply, raising the bar for spam proposals.
- The Timelock enforces a 2-day delay after queueing, giving stakeholders time to react.

### Whale domination and proposal spam
- A 4% quorum and 1% threshold reduce low-participation governance.
- High token liquidity exposes the DAO to large holders, but the system is designed to require broad participation for major changes.

### Timelock bypass
- All governance actions that affect timelock-controlled contracts flow through `RWAGovernor` and `TimelockController`.
- The governor cannot directly call controlled functions; it must queue operations through the timelock.


## 7. Oracle Attack Analysis

### Price manipulation
- `ChainlinkAdapter` rejects stale prices older than `stalePriceThreshold`.
- It also verifies `answeredInRound >= roundId` to avoid old round re-use.
- The lending pool depends on normalized price values with 18 decimals, avoiding scale mismatches.

### Proof-of-reserve manipulation
- `getProofOfReserve` applies a separate staleness threshold for PoR data.
- The adapter normalizes data to 18 decimals and rejects negative/zero values.

### Stale feed attack
- If Chainlink stops updating, the adapter reverts and prevents critical operations from proceeding.
- This means the protocol is protected against stale data, but it also means emergency pause or governance intervention is required if the feed goes dark.


## 8. Vulnerability Case Studies

### Case Study 1: Reentrancy
- **Initial risk:** Vault operations handled external ERC20 logic with potential reentrancy through a malicious token implementation.
- **Fix:** Added `nonReentrant` to `deposit`, `mint`, `withdraw`, `redeem` and used OpenZeppelin `ReentrancyGuard`.
- **Validation:** unit tests exercise deposit and redeem flows, confirming asset accounting remains intact.

### Case Study 2: Access Control
- **Initial risk:** Oracle and treasury functions were sensitive and required explicit guardrails.
- **Fix:** `ChainlinkAdapter` uses `Ownable`; `Treasury` uses `AccessControl`; `LendingPool` and `RWAVault` use `Ownable`; `RWAFactory` uses `AccessControl`.
- **Validation:** tests cover `onlyOwner` and `onlyRole` failure paths, ensuring unauthorized callers cannot mutate protocol-critical state.


## 9. Appendix: Slither and Tool Findings

### Slither results
- Slither is configured in `.github/workflows/ci.yml` with `--exclude-dependencies`.
- The CI pipeline is set to fail on High findings.
- The repository should attach the Slither SARIF report as a CI artifact.

### Test coverage
- The project includes a coverage report in `coverage-report.md`.
- Unit tests cover contract logic, and fork tests interact with live protocols.

### Documentation gap closure
- This audit report, architecture document, gas optimization report, and security audit notes are added to address previously missing deliverables.
