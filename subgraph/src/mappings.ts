import {
  Address,
  BigInt,
} from "@graphprotocol/graph-ts";
import {
  Transfer as RWATransfer,
} from "../generated/RWAToken/RWAToken";
import {
  CollateralDeposited,
  Borrowed,
  Repaid,
  Liquidated,
} from "../generated/LendingPool/LendingPool";
import {
  ProposalCreated,
  VoteCast,
  ProposalExecuted,
  ProposalCanceled,
} from "../generated/RWAGovernor/RWAGovernor";
import {
  CertificateIssued,
  CertificateRevoked,
  Transfer as CertTransfer,
} from "../generated/RWACertificate/RWACertificate";
import {
  RWAToken,
  MintEvent,
  BurnEvent,
  LendingPosition,
  BorrowEvent,
  RepayEvent,
  LiquidationEvent,
  Proposal,
  VoteEvent,
  Certificate,
  ProtocolStats,
} from "../generated/schema";

const ZERO = BigInt.fromI32(0);
const GLOBAL_ID = "global";

function getOrCreateStats(): ProtocolStats {
  let stats = ProtocolStats.load(GLOBAL_ID);
  if (!stats) {
    stats = new ProtocolStats(GLOBAL_ID);
    stats.totalRWAMinted = ZERO;
    stats.totalBorrowed = ZERO;
    stats.totalCertificates = ZERO;
    stats.lastUpdated = ZERO;
  }
  return stats;
}

function getOrCreateToken(address: Address): RWAToken {
  let id = address.toHexString();
  let token = RWAToken.load(id);
  if (!token) {
    token = new RWAToken(id);
    token.name = "RWA Token";
    token.symbol = "RWAT";
    token.totalSupply = ZERO;
  }
  return token;
}

function getOrCreatePosition(user: Address): LendingPosition {
  let id = user.toHexString();
  let pos = LendingPosition.load(id);
  if (!pos) {
    pos = new LendingPosition(id);
    pos.collateral = ZERO;
    pos.debt = ZERO;
    pos.lastUpdated = ZERO;
  }
  return pos;
}

// ─── RWA Token handlers ────────────────────────────────────────────────────

export function handleRWATransfer(event: RWATransfer): void {
  let token = getOrCreateToken(event.address);
  let stats = getOrCreateStats();
  let txId = event.transaction.hash.toHexString() + "-" + event.logIndex.toString();

  if (event.params.from == Address.zero()) {
    // Mint
    token.totalSupply = token.totalSupply.plus(event.params.value);
    token.save();

    let mint = new MintEvent(txId);
    mint.token = token.id;
    mint.to = event.params.to;
    mint.amount = event.params.value;
    mint.timestamp = event.block.timestamp;
    mint.blockNumber = event.block.number;
    mint.save();

    stats.totalRWAMinted = stats.totalRWAMinted.plus(event.params.value);
  } else if (event.params.to == Address.zero()) {
    // Burn
    if (token.totalSupply.gt(event.params.value)) {
      token.totalSupply = token.totalSupply.minus(event.params.value);
    } else {
      token.totalSupply = ZERO;
    }
    token.save();

    let burn = new BurnEvent(txId);
    burn.token = token.id;
    burn.from = event.params.from;
    burn.amount = event.params.value;
    burn.timestamp = event.block.timestamp;
    burn.blockNumber = event.block.number;
    burn.save();
  }

  stats.lastUpdated = event.block.timestamp;
  stats.save();
}

// ─── Lending pool handlers ─────────────────────────────────────────────────

export function handleCollateralDeposited(event: CollateralDeposited): void {
  let pos = getOrCreatePosition(event.params.user);
  pos.collateral = pos.collateral.plus(event.params.amount);
  pos.lastUpdated = event.block.timestamp;
  pos.save();
}

export function handleBorrowed(event: Borrowed): void {
  let pos = getOrCreatePosition(event.params.user);
  pos.debt = pos.debt.plus(event.params.amount);
  pos.lastUpdated = event.block.timestamp;
  pos.save();

  let id = event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
  let borrow = new BorrowEvent(id);
  borrow.position = pos.id;
  borrow.amount = event.params.amount;
  borrow.timestamp = event.block.timestamp;
  borrow.blockNumber = event.block.number;
  borrow.save();

  let stats = getOrCreateStats();
  stats.totalBorrowed = stats.totalBorrowed.plus(event.params.amount);
  stats.lastUpdated = event.block.timestamp;
  stats.save();
}

export function handleRepaid(event: Repaid): void {
  let pos = getOrCreatePosition(event.params.user);
  if (pos.debt.gt(event.params.amount)) {
    pos.debt = pos.debt.minus(event.params.amount);
  } else {
    pos.debt = ZERO;
  }
  pos.lastUpdated = event.block.timestamp;
  pos.save();

  let id = event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
  let repay = new RepayEvent(id);
  repay.position = pos.id;
  repay.amount = event.params.amount;
  repay.timestamp = event.block.timestamp;
  repay.blockNumber = event.block.number;
  repay.save();
}

export function handleLiquidated(event: Liquidated): void {
  let id = event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
  let liq = new LiquidationEvent(id);
  liq.borrower = event.params.borrower;
  liq.liquidator = event.params.liquidator;
  liq.debtCovered = event.params.debtCovered;
  liq.collateralSeized = event.params.collateralSeized;
  liq.timestamp = event.block.timestamp;
  liq.blockNumber = event.block.number;
  liq.save();

  let pos = getOrCreatePosition(event.params.borrower);
  pos.debt = pos.debt.minus(event.params.debtCovered);
  pos.collateral = pos.collateral.minus(event.params.collateralSeized);
  pos.lastUpdated = event.block.timestamp;
  pos.save();
}

// ─── Governor handlers ─────────────────────────────────────────────────────

export function handleProposalCreated(event: ProposalCreated): void {
  let proposal = new Proposal(event.params.proposalId.toHexString());
  proposal.proposer = event.params.proposer;
  proposal.description = event.params.description;
  proposal.state = "Pending";
  proposal.forVotes = ZERO;
  proposal.againstVotes = ZERO;
  proposal.abstainVotes = ZERO;
  proposal.startBlock = event.params.voteStart;
  proposal.endBlock = event.params.voteEnd;
  proposal.save();
}

export function handleVoteCast(event: VoteCast): void {
  let proposal = Proposal.load(event.params.proposalId.toHexString());
  if (!proposal) return;

  if (event.params.support == 1) {
    proposal.forVotes = proposal.forVotes.plus(event.params.weight);
    proposal.state = "Active";
  } else if (event.params.support == 0) {
    proposal.againstVotes = proposal.againstVotes.plus(event.params.weight);
  } else {
    proposal.abstainVotes = proposal.abstainVotes.plus(event.params.weight);
  }
  proposal.save();

  let id = event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
  let vote = new VoteEvent(id);
  vote.proposal = proposal.id;
  vote.voter = event.params.voter;
  vote.support = event.params.support;
  vote.weight = event.params.weight;
  vote.reason = event.params.reason;
  vote.timestamp = event.block.timestamp;
  vote.save();
}

export function handleProposalExecuted(event: ProposalExecuted): void {
  let proposal = Proposal.load(event.params.proposalId.toHexString());
  if (!proposal) return;
  proposal.state = "Executed";
  proposal.executedAt = event.block.timestamp;
  proposal.save();
}

export function handleProposalCanceled(event: ProposalCanceled): void {
  let proposal = Proposal.load(event.params.proposalId.toHexString());
  if (!proposal) return;
  proposal.state = "Canceled";
  proposal.canceledAt = event.block.timestamp;
  proposal.save();
}

// ─── Certificate handlers ──────────────────────────────────────────────────

export function handleCertificateIssued(event: CertificateIssued): void {
  let cert = new Certificate(event.params.tokenId.toHexString());
  cert.owner = event.params.to;
  cert.assetId = event.params.assetId;
  cert.faceValue = event.params.faceValue;
  cert.issuedAt = event.block.timestamp;
  cert.active = true;
  cert.save();

  let stats = getOrCreateStats();
  stats.totalCertificates = stats.totalCertificates.plus(BigInt.fromI32(1));
  stats.lastUpdated = event.block.timestamp;
  stats.save();
}

export function handleCertificateRevoked(event: CertificateRevoked): void {
  let cert = Certificate.load(event.params.tokenId.toHexString());
  if (!cert) return;
  cert.active = false;
  cert.save();
}

export function handleCertificateTransfer(event: CertTransfer): void {
  let cert = Certificate.load(event.params.tokenId.toHexString());
  if (!cert) return;
  cert.owner = event.params.to;
  cert.save();
}
