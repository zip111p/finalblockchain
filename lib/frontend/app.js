import { ethers } from "https://cdn.jsdelivr.net/npm/ethers@6.9.0/dist/ethers.min.js";

// ─── Contract addresses (fill in after deploy) ──────────────────────────────
const ADDRESSES = {
  rwaToken:    "0x9E42552953aB57643BcfE9538e6A836efd6460c2",
  govToken:    "0xA9C4dD622546de3F7fFDD02a905b6dc699098f86",
  vault:       "0x112b3f5DA4625B721E419671a5800C6316e3ae97",
  lendingPool: "0x57592da359112B36ffE81d2398fD47C64A4C1bEf",
  governor:    "0xC7FBe95018f1A8Ab44Ea82c18C5a7dC1Cf8029aD",
  borrowToken: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d",
};

const TARGET_CHAIN_ID = 421614; // Arbitrum Sepolia
const SUBGRAPH_URL = "https://api.studio.thegraph.com/query/YOUR_ID/rwa-platform/v0.0.1";

// ─── Minimal ABIs ────────────────────────────────────────────────────────────
const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function allowance(address,address) view returns (uint256)",
  "function decimals() view returns (uint8)",
];
const GOV_TOKEN_ABI = [
  ...ERC20_ABI,
  "function getVotes(address) view returns (uint256)",
  "function delegates(address) view returns (address)",
  "function delegate(address)",
];
const VAULT_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function deposit(uint256,address) returns (uint256)",
  "function redeem(uint256,address,address) returns (uint256)",
  "function previewDeposit(uint256) view returns (uint256)",
  "function asset() view returns (address)",
];
const LENDING_ABI = [
  "function depositCollateral(uint256)",
  "function borrow(uint256)",
  "function repay(uint256)",
  "function provideLiquidity(uint256)",
  "function availableLiquidity() view returns (uint256)",
  "function positions(address) view returns (uint256 collateral, uint256 scaledDebt)",
  "function healthFactor(address) view returns (uint256)",
  "function currentDebt(address) view returns (uint256)",
];
const GOVERNOR_ABI = [
  "function castVote(uint256 proposalId, uint8 support) returns (uint256)",
  "function state(uint256 proposalId) view returns (uint8)",
  "function proposalSnapshot(uint256 proposalId) view returns (uint256)",
  "function proposalDeadline(uint256 proposalId) view returns (uint256)",
  "function proposalVotes(uint256 proposalId) view returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes)",
];

// Known on-chain proposals (populated at deploy time)
const KNOWN_PROPOSALS = [
  {
    id: "321069811781797758511696746920503563840038788315689291221976290216621435195",
    description: "RIP-1: Initialize RWA Platform treasury and establish governance lifecycle",
  },
];

// ─── State ───────────────────────────────────────────────────────────────────
let provider, signer, account;
const STATES = ["Pending","Active","Canceled","Defeated","Succeeded","Queued","Expired","Executed"];

// ─── Helpers ─────────────────────────────────────────────────────────────────
function fmt(val, dec = 18) {
  return parseFloat(ethers.formatUnits(val, dec)).toFixed(4);
}
function showError(id, msg) {
  const el = document.getElementById(id);
  el.textContent = msg;
  el.classList.remove("hidden");
  setTimeout(() => el.classList.add("hidden"), 8000);
}
function showSuccess(id, msg) {
  const el = document.getElementById(id);
  el.textContent = msg;
  el.classList.remove("hidden");
  setTimeout(() => el.classList.add("hidden"), 5000);
}
function setEl(id, val) { document.getElementById(id).textContent = val; }

// ─── Network detection ────────────────────────────────────────────────────────
async function checkNetwork() {
  const network = await provider.getNetwork();
  const wrongNet = document.getElementById("wrong-network");
  if (Number(network.chainId) !== TARGET_CHAIN_ID) {
    wrongNet.classList.remove("hidden");
    return false;
  }
  wrongNet.classList.add("hidden");
  return true;
}

document.getElementById("btn-switch-network").addEventListener("click", async (e) => {
  e.preventDefault();
  try {
    await window.ethereum.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: "0x" + TARGET_CHAIN_ID.toString(16) }],
    });
  } catch (err) {
    // If chain not added, add it
    if (err.code === 4902) {
      await window.ethereum.request({
        method: "wallet_addEthereumChain",
        params: [{
          chainId: "0x" + TARGET_CHAIN_ID.toString(16),
          chainName: "Arbitrum Sepolia",
          rpcUrls: ["https://sepolia-rollup.arbitrum.io/rpc"],
          nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
          blockExplorerUrls: ["https://sepolia.arbiscan.io"],
        }],
      });
    }
  }
});

// ─── Connect wallet ───────────────────────────────────────────────────────────
document.getElementById("btn-connect").addEventListener("click", async () => {
  if (!window.ethereum) { alert("MetaMask not found"); return; }
  try {
    provider = new ethers.BrowserProvider(window.ethereum);
    await provider.send("eth_requestAccounts", []);
    signer = await provider.getSigner();
    account = await signer.getAddress();

    const shortAddr = account.slice(0, 6) + "..." + account.slice(-4);
    setEl("wallet-address", shortAddr);
    document.getElementById("wallet-address").classList.remove("hidden");
    document.getElementById("btn-connect").textContent = "Connected";
    document.getElementById("btn-connect").disabled = true;

    await checkNetwork();
    await loadBalances();
    await loadSubgraphStats();
    await loadLendingPosition();
    await loadProposals();

    window.ethereum.on("chainChanged", () => window.location.reload());
    window.ethereum.on("accountsChanged", () => window.location.reload());
  } catch (err) {
    showError("vault-error", "Connection failed: " + err.message);
  }
});

// ─── Load balances ────────────────────────────────────────────────────────────
async function loadBalances() {
  try {
    const rwa = new ethers.Contract(ADDRESSES.rwaToken, ERC20_ABI, provider);
    const gov = new ethers.Contract(ADDRESSES.govToken, GOV_TOKEN_ABI, provider);
    const vault = new ethers.Contract(ADDRESSES.vault, VAULT_ABI, provider);

    const [rwaBalance, votes, delegate, vaultShares] = await Promise.all([
      rwa.balanceOf(account),
      gov.getVotes(account),
      gov.delegates(account),
      vault.balanceOf(account),
    ]);

    setEl("rwa-balance", fmt(rwaBalance) + " RWAT");
    setEl("gov-votes", fmt(votes) + " RWAGOV");
    setEl("gov-delegate", delegate === ethers.ZeroAddress ? "Not delegated" : delegate.slice(0,10)+"...");
    setEl("vault-shares", fmt(vaultShares) + " vRWAT");
  } catch (err) {
    console.error("loadBalances:", err);
  }
}

// ─── Subgraph stats ────────────────────────────────────────────────────────────
async function loadSubgraphStats() {
  const query = `{ protocolStats(id: "global") { totalRWAMinted totalBorrowed totalCertificates } }`;
  try {
    const res = await fetch(SUBGRAPH_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query }),
    });
    const data = await res.json();
    const stats = data?.data?.protocolStats;
    if (stats) {
      setEl("total-minted", fmt(stats.totalRWAMinted) + " RWAT");
      setEl("total-borrowed", fmt(stats.totalBorrowed));
      setEl("total-certs", stats.totalCertificates);
    }
  } catch (err) {
    document.getElementById("pool-error").textContent = "Subgraph unavailable";
    document.getElementById("pool-error").classList.remove("hidden");
  }
}

// ─── Lending position ──────────────────────────────────────────────────────────
async function loadLendingPosition() {
  try {
    const pool = new ethers.Contract(ADDRESSES.lendingPool, LENDING_ABI, provider);
    const [pos, debt, hf, liq] = await Promise.all([
      pool.positions(account),
      pool.currentDebt(account),
      pool.healthFactor(account),
      pool.availableLiquidity(),
    ]);
    setEl("loan-collateral", fmt(pos.collateral) + " RWAT");
    setEl("loan-debt", fmt(debt));
    const hfNum = parseFloat(ethers.formatUnits(hf, 18));
    setEl("loan-health", hf === ethers.MaxUint256 ? "∞" : hfNum.toFixed(2));
    setEl("pool-liquidity", fmt(liq) + " USDC");
  } catch (err) {
    console.error("loadLendingPosition:", err);
  }
}

// ─── Vault deposit ─────────────────────────────────────────────────────────────
document.getElementById("btn-deposit").addEventListener("click", async () => {
  if (!signer) return showError("vault-error", "Connect wallet first");
  if (!(await checkNetwork())) return;
  const amtStr = document.getElementById("input-deposit").value;
  if (!amtStr || isNaN(amtStr)) return showError("vault-error", "Enter a valid amount");
  try {
    const amount = ethers.parseEther(amtStr);
    const rwa = new ethers.Contract(ADDRESSES.rwaToken, ERC20_ABI, signer);
    const vault = new ethers.Contract(ADDRESSES.vault, VAULT_ABI, signer);
    const allowance = await rwa.allowance(account, ADDRESSES.vault);
    if (allowance < amount) {
      const tx = await rwa.approve(ADDRESSES.vault, amount);
      await tx.wait();
    }
    const tx = await vault.deposit(amount, account);
    await tx.wait();
    showSuccess("vault-success", "Deposit successful!");
    await loadBalances();
  } catch (err) {
    const msg = err?.info?.error?.message || err.message || "Transaction failed";
    showError("vault-error", msg);
  }
});

// ─── Vault redeem ──────────────────────────────────────────────────────────────
document.getElementById("btn-redeem").addEventListener("click", async () => {
  if (!signer) return showError("vault-error", "Connect wallet first");
  if (!(await checkNetwork())) return;
  const sharesStr = document.getElementById("input-withdraw").value;
  if (!sharesStr || isNaN(sharesStr)) return showError("vault-error", "Enter valid shares");
  try {
    const shares = ethers.parseEther(sharesStr);
    const vault = new ethers.Contract(ADDRESSES.vault, VAULT_ABI, signer);
    const tx = await vault.redeem(shares, account, account);
    await tx.wait();
    showSuccess("vault-success", "Redeem successful!");
    await loadBalances();
  } catch (err) {
    const msg = err?.info?.error?.message || err.message || "Transaction failed";
    showError("vault-error", msg);
  }
});

// ─── Lending: provide liquidity ──────────────────────────────────────────────
document.getElementById("btn-provide-liquidity").addEventListener("click", async () => {
  if (!signer) return showError("lending-error", "Connect wallet first");
  if (!(await checkNetwork())) return;
  const amtStr = document.getElementById("input-provide-liquidity").value;
  if (!amtStr || isNaN(amtStr)) return showError("lending-error", "Enter a valid amount");
  try {
    const amount = ethers.parseEther(amtStr);
    const usdc = new ethers.Contract(ADDRESSES.borrowToken, ERC20_ABI, signer);
    const pool = new ethers.Contract(ADDRESSES.lendingPool, LENDING_ABI, signer);
    const allowance = await usdc.allowance(account, ADDRESSES.lendingPool);
    if (allowance < amount) {
      const tx = await usdc.approve(ADDRESSES.lendingPool, amount);
      await tx.wait();
    }
    const tx = await pool.provideLiquidity(amount);
    await tx.wait();
    showSuccess("lending-success", "Liquidity provided!");
    await loadLendingPosition();
  } catch (err) {
    const msg = err?.info?.error?.message || err.message || "Transaction failed";
    showError("lending-error", msg);
  }
});

// ─── Lending: deposit collateral ──────────────────────────────────────────────
document.getElementById("btn-deposit-collateral").addEventListener("click", async () => {
  if (!signer) return showError("lending-error", "Connect wallet first");
  if (!(await checkNetwork())) return;
  const amtStr = document.getElementById("input-collateral").value;
  if (!amtStr || isNaN(amtStr)) return showError("lending-error", "Enter a valid amount");
  try {
    const amount = ethers.parseEther(amtStr);
    const rwa = new ethers.Contract(ADDRESSES.rwaToken, ERC20_ABI, signer);
    const pool = new ethers.Contract(ADDRESSES.lendingPool, LENDING_ABI, signer);
    const allowance = await rwa.allowance(account, ADDRESSES.lendingPool);
    if (allowance < amount) {
      const tx = await rwa.approve(ADDRESSES.lendingPool, amount);
      await tx.wait();
    }
    const tx = await pool.depositCollateral(amount);
    await tx.wait();
    showSuccess("lending-success", "Collateral deposited!");
    await loadBalances();
    await loadLendingPosition();
  } catch (err) {
    const msg = err?.info?.error?.message || err.message || "Transaction failed";
    showError("lending-error", msg);
  }
});

// ─── Lending: borrow ──────────────────────────────────────────────────────────
document.getElementById("btn-borrow").addEventListener("click", async () => {
  if (!signer) return showError("lending-error", "Connect wallet first");
  if (!(await checkNetwork())) return;
  const amtStr = document.getElementById("input-borrow").value;
  if (!amtStr || isNaN(amtStr)) return showError("lending-error", "Enter a valid amount");
  try {
    const amount = ethers.parseEther(amtStr);
    const pool = new ethers.Contract(ADDRESSES.lendingPool, LENDING_ABI, signer);
    const tx = await pool.borrow(amount);
    await tx.wait();
    showSuccess("lending-success", "Borrow successful!");
    await loadBalances();
    await loadLendingPosition();
  } catch (err) {
    const msg = err?.info?.error?.message || err.message || "Transaction failed";
    showError("lending-error", msg);
  }
});

// ─── Governance proposals (subgraph with on-chain fallback) ───────────────────
async function loadProposals() {
  const query = `{
    proposals(first: 10, orderBy: startBlock, orderDirection: desc) {
      id description state forVotes againstVotes abstainVotes startBlock endBlock
    }
  }`;
  const container = document.getElementById("proposals-list");

  // Try subgraph first
  try {
    const res = await fetch(SUBGRAPH_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query }),
    });
    const data = await res.json();
    const proposals = data?.data?.proposals || [];
    if (proposals.length) {
      renderSubgraphProposals(proposals, container);
      return;
    }
  } catch (_) { /* fall through to on-chain */ }

  // Fallback: query known proposals directly from the Governor contract
  await loadProposalsOnChain(container);
}

function renderSubgraphProposals(proposals, container) {
  container.innerHTML = proposals.map(p => {
    const total = BigInt(p.forVotes) + BigInt(p.againstVotes) + BigInt(p.abstainVotes);
    const forPct = total > 0n ? Number((BigInt(p.forVotes) * 100n) / total) : 0;
    return `<div class="proposal ${p.state}">
      <div class="proposal-header">
        <strong>${p.description.slice(0, 80)}${p.description.length > 80 ? "…" : ""}</strong>
        <span class="proposal-state">${p.state}</span>
      </div>
      <div class="vote-bar"><div class="vote-bar-inner" style="width:${forPct}%"></div></div>
      <small>For: ${fmt(p.forVotes)} | Against: ${fmt(p.againstVotes)}</small>
      ${p.state === "Active" ? `<button class="btn-vote" data-id="${p.id}">Vote For</button>` : ""}
    </div>`;
  }).join("");
  container.querySelectorAll(".btn-vote").forEach(btn => {
    btn.addEventListener("click", () => castVote(btn.dataset.id, 1));
  });
}

async function loadProposalsOnChain(container) {
  try {
    const gov = new ethers.Contract(ADDRESSES.governor, GOVERNOR_ABI, provider);
    const cards = await Promise.all(KNOWN_PROPOSALS.map(async (p) => {
      const [stateNum, votes] = await Promise.all([
        gov.state(p.id),
        gov.proposalVotes(p.id),
      ]);
      const stateName = STATES[Number(stateNum)] ?? "Unknown";
      const forVotes = votes.forVotes;
      const againstVotes = votes.againstVotes;
      const total = forVotes + againstVotes + votes.abstainVotes;
      const forPct = total > 0n ? Number((forVotes * 100n) / total) : 0;
      return `<div class="proposal ${stateName}">
        <div class="proposal-header">
          <strong>${p.description.slice(0, 80)}${p.description.length > 80 ? "…" : ""}</strong>
          <span class="proposal-state">${stateName}</span>
        </div>
        <div class="vote-bar"><div class="vote-bar-inner" style="width:${forPct}%"></div></div>
        <small>For: ${fmt(forVotes)} | Against: ${fmt(againstVotes)}</small>
        ${stateName === "Active" ? `<button class="btn-vote" data-id="${p.id}">Vote For</button>` : ""}
      </div>`;
    }));
    container.innerHTML = cards.join("") || "<p>No proposals found.</p>";
    container.querySelectorAll(".btn-vote").forEach(btn => {
      btn.addEventListener("click", () => castVote(btn.dataset.id, 1));
    });
  } catch (err) {
    showError("gov-error", "Could not load proposals: " + err.message);
  }
}

async function castVote(proposalId, support) {
  if (!signer) return showError("gov-error", "Connect wallet first");
  if (!(await checkNetwork())) return;
  try {
    const gov = new ethers.Contract(ADDRESSES.governor, GOVERNOR_ABI, signer);
    const tx = await gov.castVote(proposalId, support);
    await tx.wait();
    showSuccess("gov-error", "Vote cast successfully!");
    await loadProposals();
  } catch (err) {
    const msg = err?.info?.error?.message || err.message || "Vote failed";
    showError("gov-error", msg);
  }
}
