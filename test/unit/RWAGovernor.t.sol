// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {RWAGovernor} from "../../src/governance/RWAGovernor.sol";
import {GovernanceToken} from "../../src/tokens/GovernanceToken.sol";
import {Treasury} from "../../src/governance/Treasury.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract RWAGovernorTest is Test {
    GovernanceToken public govToken;
    TimelockController public timelock;
    RWAGovernor public governor;
    Treasury public treasury;
    MockERC20 public rewardToken;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice"); // major voter
    address public bob = makeAddr("bob");
    address public proposer = makeAddr("proposer");

    uint256 constant TOTAL_SUPPLY = 10_000_000e18;
    uint256 constant QUORUM_SUPPLY = (TOTAL_SUPPLY * 4) / 100; // 4%
    uint256 constant PROPOSAL_THRESHOLD = TOTAL_SUPPLY / 100; // 1%
    uint256 constant TIMELOCK_DELAY = 2 days;
    uint48  constant VOTING_DELAY  = 1;
    uint32  constant VOTING_PERIOD = uint32(TIMELOCK_DELAY);

    function setUp() public {
        // Deploy governance token
        govToken = new GovernanceToken(admin);
        vm.startPrank(admin);
        govToken.mint(alice, TOTAL_SUPPLY * 90 / 100);  // 90% to alice
        govToken.mint(proposer, TOTAL_SUPPLY * 10 / 100); // 10% to proposer
        vm.stopPrank();

        // Delegate votes
        vm.prank(alice);
        govToken.delegate(alice);
        vm.prank(proposer);
        govToken.delegate(proposer);

        // Deploy Timelock
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = address(0); // anyone can propose
        executors[0] = address(0); // anyone can execute after timelock
        timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, admin);

        // Deploy Governor
        governor = new RWAGovernor(govToken, timelock, PROPOSAL_THRESHOLD, VOTING_DELAY, VOTING_PERIOD);

        // Grant governor proposer + canceller role on timelock
        vm.startPrank(admin);
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        vm.stopPrank();

        // Deploy treasury with timelock as controller
        treasury = new Treasury(address(timelock));

        rewardToken = new MockERC20("Reward", "RWD", 18);
        rewardToken.mint(address(treasury), 10_000e18);
    }

    // ── propose ───────────────────────────────────────────────────────────────

    function test_propose_succeeds() public {
        vm.roll(block.number + 1);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory desc) =
            _buildProposal();
        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, desc);
        assertGt(proposalId, 0);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));
    }

    function test_propose_revertsIfBelowThreshold() public {
        vm.roll(block.number + 1);
        address lowBal = makeAddr("lowBal");
        vm.prank(admin);
        govToken.mint(lowBal, PROPOSAL_THRESHOLD - 1e18);
        vm.prank(lowBal);
        govToken.delegate(lowBal);
        vm.roll(block.number + 1);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory desc) =
            _buildProposal();
        vm.prank(lowBal);
        vm.expectRevert();
        governor.propose(targets, values, calldatas, desc);
    }

    // ── full lifecycle: propose → vote → queue → execute ─────────────────────

    function test_fullLifecycle() public {
        vm.roll(block.number + 1);

        // 1. Propose
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory desc) =
            _buildProposal();
        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, desc);

        // 2. Wait for voting delay
        vm.roll(block.number + governor.votingDelay() + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));

        // 3. Vote (alice has 90% > 4% quorum)
        vm.prank(alice);
        governor.castVote(proposalId, 1); // 1 = For

        // 4. Wait for voting period
        vm.roll(block.number + governor.votingPeriod() + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        // 5. Queue
        bytes32 descHash = keccak256(bytes(desc));
        governor.queue(targets, values, calldatas, descHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        // 6. Wait for timelock
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // 7. Execute
        governor.execute(targets, values, calldatas, descHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
    }

    function test_vote_against_defeats_proposal() public {
        vm.roll(block.number + 1);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory desc) =
            _buildProposal();
        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, desc);
        vm.roll(block.number + governor.votingDelay() + 1);
        // Alice votes against
        vm.prank(alice);
        governor.castVote(proposalId, 0); // 0 = Against
        vm.roll(block.number + governor.votingPeriod() + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_governance_params() public view {
        assertEq(governor.votingDelay(), VOTING_DELAY);
        assertEq(governor.votingPeriod(), VOTING_PERIOD);
        assertEq(governor.proposalThreshold(), PROPOSAL_THRESHOLD);
    }

    function test_quorum_returnsNonZero() public {
        vm.roll(block.number + 1);
        uint256 q = governor.quorum(block.number - 1);
        assertGt(q, 0);
    }

    function test_proposalNeedsQueuing_returnsTrue() public {
        vm.roll(block.number + 1);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory desc) =
            _buildProposal();
        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, desc);
        assertTrue(governor.proposalNeedsQueuing(proposalId));
    }

    function test_cancel_cancelsPendingProposal() public {
        vm.roll(block.number + 1);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory desc) =
            _buildProposal();
        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, desc);

        bytes32 descHash = keccak256(bytes(desc));
        vm.prank(proposer);
        governor.cancel(targets, values, calldatas, descHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));
    }

    function test_timelock_returnsTimelockAddress() public view {
        assertEq(governor.timelock(), address(timelock));
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _buildProposal()
        internal
        view
        returns (address[] memory, uint256[] memory, bytes[] memory, string memory)
    {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(treasury);
        values[0] = 0;
        calldatas[0] = abi.encodeCall(
            treasury.allocate,
            (address(rewardToken), alice, 100e18)
        );
        return (targets, values, calldatas, "Proposal: allocate 100 RWD to alice");
    }
}
