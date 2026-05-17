# Git Setup & Commit Instructions

## Initial setup (run once)

```bash
cd RWA-Tokenization-Platform

# Initialize git
git init
git remote add origin https://github.com/AlmasAlkhan/Final-Project.git

# Create develop branch
git checkout -b develop

# First commit — project scaffold
git add foundry.toml remappings.txt .solhint.json .prettierrc .env.example README.md
git commit -m "chore: initialize foundry project with config and remappings"

git push -u origin develop
```

---

## Branch per feature (Conventional Commits required)

### Person 1 — feat/uups-proxy

```bash
git checkout develop
git pull origin develop
git checkout -b feat/uups-proxy

git add src/tokens/RWAToken.sol src/tokens/RWATokenV2.sol
git commit -m "feat(rwa-token): implement UUPS upgradeable ERC-20 with role-gated minting"

git add test/unit/RWAToken.t.sol
git commit -m "test(rwa-token): add unit tests for V1 initialize, mint, burn, pause, upgrade"

git push origin feat/uups-proxy
# → GitHub: open PR → develop, wait for CI ✅, merge
```

### Person 1 — feat/amm-core (lending pool for Option C)

```bash
git checkout develop && git pull
git checkout -b feat/lending-pool

git add src/lending/LendingPool.sol
git commit -m "feat(lending): implement RWA-collateralized lending with linear interest rate"

git add src/factory/RWAFactory.sol
git commit -m "feat(factory): add CREATE and CREATE2 deployment via RWAFactory"

git add src/utils/AssemblyUtils.sol
git commit -m "feat(assembly): add Yul-optimized math utils with Solidity benchmark equivalents"

git add test/unit/LendingPool.t.sol test/unit/RWAFactory.t.sol test/unit/AssemblyUtils.t.sol
git commit -m "test(lending,factory,assembly): add unit tests covering all public functions"

git add test/fuzz/FuzzLending.t.sol
git commit -m "test(lending): add fuzz tests for borrow LTV bounds and repay correctness"

git add test/invariant/InvariantLending.t.sol
git commit -m "test(lending): add invariant tests for pool solvency and collateral accounting"

git push origin feat/lending-pool
# → PR → develop
```

### Person 2 — feat/governance

```bash
git checkout develop && git pull
git checkout -b feat/governance

git add src/tokens/GovernanceToken.sol src/governance/RWAGovernor.sol src/governance/Treasury.sol
git commit -m "feat(governance): add ERC20Votes token, OZ Governor stack, and Treasury"

git add test/unit/GovernanceToken.t.sol test/unit/RWAGovernor.t.sol
git commit -m "test(governance): add propose→vote→queue→execute lifecycle test"

git push origin feat/governance
```

### Person 2 — feat/chainlink-oracles

```bash
git checkout develop && git pull
git checkout -b feat/chainlink-oracles

git add src/oracle/IChainlinkAdapter.sol src/oracle/ChainlinkAdapter.sol
git commit -m "feat(oracle): implement Chainlink price feed + PoR adapter with staleness check"

git add src/tokens/RWACertificate.sol
git commit -m "feat(certificate): add ERC-721 RWA ownership certificate with expiry"

git add test/unit/ChainlinkAdapter.t.sol test/unit/RWACertificate.t.sol
git commit -m "test(oracle,certificate): add unit tests for staleness, normalization, issuance"

git add test/fork/ForkChainlink.t.sol test/fork/ForkUSDC.t.sol
git commit -m "test(fork): add mainnet fork tests against real Chainlink feeds and USDC"

git push origin feat/chainlink-oracles
```

### Person 3 — feat/vault-subgraph-frontend

```bash
git checkout develop && git pull
git checkout -b feat/vault-subgraph

git add src/vault/RWAVault.sol
git commit -m "feat(vault): implement ERC-4626 yield vault with yield accrual and pause"

git add test/unit/RWAVault.t.sol test/fuzz/FuzzVault.t.sol test/invariant/InvariantVault.t.sol
git commit -m "test(vault): add unit, fuzz, and invariant tests for ERC-4626 rounding invariants"

git add subgraph/
git commit -m "feat(subgraph): add Graph Protocol schema with 8 entities and event mappings"

git add frontend/
git commit -m "feat(frontend): add dApp with wallet connect, vault deposit, lending, governance"

git push origin feat/vault-subgraph
```

### Person 3 — ci/github-actions

```bash
git checkout develop && git pull
git checkout -b ci/github-actions

git add .github/ .solhint.json .prettierrc
git commit -m "ci: add GitHub Actions pipeline with forge test, coverage, solhint, slither"

git push origin ci/github-actions
```

### Deployment (all together)

```bash
git checkout develop && git pull
git checkout -b feat/l2-deployment

git add script/Deploy.s.sol script/Verify.s.sol
git commit -m "feat(deploy): add idempotent deployment script and post-deploy verification"

# After actual deployment:
git add README.md  # add contract addresses
git commit -m "docs: add deployed contract addresses for Arbitrum Sepolia"

git push origin feat/l2-deployment
```

### Final merge to main

```bash
# After all PRs merged into develop:
git checkout main
git merge develop
git tag v1.0.0
git push origin main --tags
```

---

## Branch protection rules (set on GitHub)

Settings → Branches → Add rule:
- Branch name: `main` and `develop`
- ✅ Require pull request reviews (1 reviewer)
- ✅ Require status checks: `test`, `lint`, `slither`
- ✅ Require branches to be up to date