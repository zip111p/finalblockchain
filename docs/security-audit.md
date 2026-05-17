# Security Audit Notes

## 1. Overview

This security audit file provides a concise review of the protocol's security posture, including vulnerability case studies, remediation notes, and recommendations for hardening before mainnet deployment.

The platform is composed of the following security-relevant domains:
- upgradeable token logic (`RWAToken` / `RWATokenV2`)
- oracle integration (`ChainlinkAdapter`)
- vault mechanics (`RWAVault`)
- lending mechanics (`LendingPool`)
- governance and treasury control (`RWAGovernor`, `TimelockController`, `Treasury`)
- certificate factory and asset minting (`RWAFactory`, `RWACertificate`)


## 2. Security Controls

### 2.1 Access Control

All privileged functions use either `Ownable` or `AccessControl`.
- `GovernanceToken`: `onlyOwner` minting
- `RWAToken`: `MINTER_ROLE`, `PAUSER_ROLE`, `UPGRADER_ROLE`
- `RWATokenV2`: `FEE_MANAGER_ROLE`, `WHITELIST_ROLE`
- `RWACertificate`: `ISSUER_ROLE`, `PAUSER_ROLE`
- `LendingPool`: `onlyOwner` for oracle update and liquidity withdrawal
- `RWAVault`: `onlyOwner` for yield rate and pause control
- `ChainlinkAdapter`: `onlyOwner` for feed updates
- `Treasury`: `AccessControl` with `EXECUTOR_ROLE`
- `RWAFactory`: `DEPLOYER_ROLE`

### 2.2 Reentrancy Protection

`ReentrancyGuard` is applied in:
- `RWAVault` for deposit, mint, withdraw, redeem
- `LendingPool` for liquidity, collateral, borrow, repay, liquidate
- `Treasury` for ETH transfer and token allocation claim

### 2.3 Pull-over-Push Payments

`Treasury` uses a pull payment model for ERC20 token allocation. Funds are allocated to a recipient and claimed separately. This avoids unsafe push patterns.

### 2.4 Oracle Safety

`ChainlinkAdapter` enforces the following checks:
- `answer > 0`
- `updatedAt != 0`
- `block.timestamp - updatedAt <= staleThreshold`
- `answeredInRound >= roundId`

Separate staleness thresholds are used for price and proof-of-reserve feeds.

### 2.5 Pausable Circuit Breakers

Several contracts support pausing:
- `RWAToken` via `ERC20PausableUpgradeable`
- `RWACertificate` via `Pausable`
- `RWAVault` via `Pausable`
- `LendingPool` via `Pausable`

This enables emergency response while preserving read-only access.


## 3. Vulnerability Case Study 1: Reentrancy

### 3.1 Problem
Vault deposit and redeem functions perform asset transfers across external ERC20 tokens.

### 3.2 Risk
A malicious ERC20 token could call back into the vault during `safeTransferFrom` or `safeTransfer`, causing repeated state changes.

### 3.3 Fix
The vault now applies `nonReentrant` to all external state-changing entry points and accrues yield before transfer operations.

### 3.4 Validation
Tests cover `deposit` / `redeem` and ensure `totalAssets()` retains expected values after operations. The guard prevents recursive entry into the same function.


## 4. Vulnerability Case Study 2: Access Control Failure

### 4.1 Problem
Critical functions controlling oracle feeds, treasury assets, and upgradeability were at risk of insufficient guardrails.

### 4.2 Risk
Unauthorized actors could change oracle feeds, withdraw treasury funds, or upgrade token logic.

### 4.3 Fix
All sensitive paths are now gated with explicit role checks and `Ownable`:
- `ChainlinkAdapter`: `onlyOwner`
- `Treasury`: `EXECUTOR_ROLE`
- `RWAToken`: `UPGRADER_ROLE`
- `RWACertificate`: `ISSUER_ROLE`
- `RWAFactory`: `DEPLOYER_ROLE`

### 4.4 Validation
Unit tests verify that unauthorized callers revert when attempting to access restricted functions.


## 5. Contract-Specific Security Observations

### 5.1 RWAToken / RWATokenV2
- Custom storage slots are used to preserve upgrade safety.
- `initialize` sets up roles and disables initializers in the constructor.
- `RWATokenV2` correctly appends storage in a new slot and grants roles on initialization.
- Recommendation: deploy `UPGRADER_ROLE` to the Timelock or a multisig.

### 5.2 RWAVault
- Yield accrual is deterministic and only updated on user actions.
- `totalAssets()` includes pending yield and avoids undercounting by adding one to denominators in rounding.
- All external functions are `nonReentrant` and `whenNotPaused`.

### 5.3 LendingPool
- Debt is tracked via `scaledDebt` and a global `debtIndex`.
- `borrow` and `repay` use CEI semantics.
- Liquidation requires the position to be unhealthy and computes collateral based on `ChainlinkAdapter` price.
- Recommendation: validate that a malicious oracle cannot cause collateral seizures by using a trusted multisig or Timelock for adapter ownership.

### 5.4 Governance and Treasury
- `RWAGovernor` uses OpenZeppelin Governor settings with 1-day delay, 1-week period, 4% quorum.
- `TimelockController` is configured with a 2-day delay and is granted proposer/canceller roles.
- `Treasury` only allows resource allocation through `EXECUTOR_ROLE`, promoting on-chain control.


## 6. Remaining Recommendations

### 6.1 Role Management
- Confirm that `MINTER_ROLE`, `UPGRADER_ROLE`, and `ISSUER_ROLE` are granted only to trusted addresses.
- Consider a governance-managed multisig for `ChainlinkAdapter` ownership.

### 6.2 Monitoring
- Monitor Chainlink feed health and ensure fallback mechanisms are ready if feeds become stale.
- Track timelock queue state and proposal execution status in the frontend.

### 6.3 Documentation
- Maintain a clear role map in documentation to avoid ambiguity during audits.
- Document how emergency pause and token freezing are triggered.


## 7. Conclusion

The project demonstrates strong security hygiene for a student capstone:
- Access control is explicit and role-based
- Reentrancy guards are deployed on sensitive flows
- Oracle staleness checks protect data integrity
- Governance uses a timelock-based execution model

The remaining hardening items are primarily operational:
- move critical upgrade/oracle owner roles to a governed address
- keep role assignments minimal and auditable
- continue running `slither` and `forge coverage` as part of CI
