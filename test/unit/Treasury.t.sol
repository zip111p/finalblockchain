// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Treasury} from "../../src/governance/Treasury.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract TreasuryTest is Test {
    Treasury public treasury;
    MockERC20 public token;

    address public timelock  = makeAddr("timelock");
    address public alice     = makeAddr("alice");
    address public attacker  = makeAddr("attacker");

    function setUp() public {
        treasury = new Treasury(timelock);
        token    = new MockERC20("USD", "USD", 18);
    }

    // ── constructor ──────────────────────────────────────────────────────────

    function test_constructor_timelockHasExecutorRole() public view {
        assertTrue(treasury.hasRole(treasury.EXECUTOR_ROLE(), timelock));
    }

    function test_constructor_timelockHasAdminRole() public view {
        assertTrue(treasury.hasRole(treasury.DEFAULT_ADMIN_ROLE(), timelock));
    }

    // ── receive ETH ──────────────────────────────────────────────────────────

    function test_receive_acceptsEther() public {
        deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(treasury).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(treasury).balance, 1 ether);
    }

    function test_receive_emitsEvent() public {
        deal(alice, 1 ether);
        vm.expectEmit(true, false, false, true);
        emit Treasury.EtherReceived(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(treasury).call{value: 1 ether}("");
        assertTrue(ok);
    }

    // ── allocate ─────────────────────────────────────────────────────────────

    function test_allocate_setsClaimableAmount() public {
        token.mint(address(treasury), 1000e18);
        vm.prank(timelock);
        treasury.allocate(address(token), alice, 500e18);
        assertEq(treasury.claimable(address(token), alice), 500e18);
    }

    function test_allocate_accumulatesMultipleCalls() public {
        token.mint(address(treasury), 1000e18);
        vm.startPrank(timelock);
        treasury.allocate(address(token), alice, 300e18);
        treasury.allocate(address(token), alice, 200e18);
        vm.stopPrank();
        assertEq(treasury.claimable(address(token), alice), 500e18);
    }

    function test_allocate_emitsFundsAllocated() public {
        token.mint(address(treasury), 1000e18);
        vm.expectEmit(true, true, false, true);
        emit Treasury.FundsAllocated(address(token), alice, 500e18);
        vm.prank(timelock);
        treasury.allocate(address(token), alice, 500e18);
    }

    function test_allocate_revertsZeroRecipient() public {
        vm.prank(timelock);
        vm.expectRevert("Zero recipient");
        treasury.allocate(address(token), address(0), 100e18);
    }

    function test_allocate_revertsZeroAmount() public {
        vm.prank(timelock);
        vm.expectRevert("Zero amount");
        treasury.allocate(address(token), alice, 0);
    }

    function test_allocate_revertsIfNotExecutor() public {
        vm.prank(attacker);
        vm.expectRevert();
        treasury.allocate(address(token), alice, 100e18);
    }

    // ── claim ────────────────────────────────────────────────────────────────

    function test_claim_transfersTokens() public {
        token.mint(address(treasury), 1000e18);
        vm.prank(timelock);
        treasury.allocate(address(token), alice, 400e18);

        vm.prank(alice);
        treasury.claim(address(token));
        assertEq(token.balanceOf(alice), 400e18);
    }

    function test_claim_zerosClaimableAfterClaim() public {
        token.mint(address(treasury), 1000e18);
        vm.prank(timelock);
        treasury.allocate(address(token), alice, 400e18);

        vm.prank(alice);
        treasury.claim(address(token));
        assertEq(treasury.claimable(address(token), alice), 0);
    }

    function test_claim_emitsFundsClaimed() public {
        token.mint(address(treasury), 1000e18);
        vm.prank(timelock);
        treasury.allocate(address(token), alice, 400e18);

        vm.expectEmit(true, true, false, true);
        emit Treasury.FundsClaimed(address(token), alice, 400e18);
        vm.prank(alice);
        treasury.claim(address(token));
    }

    function test_claim_revertsNothingToClaim() public {
        vm.prank(alice);
        vm.expectRevert("Nothing to claim");
        treasury.claim(address(token));
    }

    function test_claim_cannotClaimTwice() public {
        token.mint(address(treasury), 1000e18);
        vm.prank(timelock);
        treasury.allocate(address(token), alice, 400e18);

        vm.startPrank(alice);
        treasury.claim(address(token));
        vm.expectRevert("Nothing to claim");
        treasury.claim(address(token));
        vm.stopPrank();
    }

    // ── sendEth ──────────────────────────────────────────────────────────────

    function test_sendEth_sendsEtherToRecipient() public {
        deal(address(treasury), 2 ether);
        vm.prank(timelock);
        treasury.sendEth(payable(alice), 1 ether);
        assertEq(alice.balance, 1 ether);
        assertEq(address(treasury).balance, 1 ether);
    }

    function test_sendEth_revertsZeroRecipient() public {
        deal(address(treasury), 1 ether);
        vm.prank(timelock);
        vm.expectRevert("Zero recipient");
        treasury.sendEth(payable(address(0)), 0.5 ether);
    }

    function test_sendEth_revertsInsufficientBalance() public {
        vm.prank(timelock);
        vm.expectRevert("Insufficient balance");
        treasury.sendEth(payable(alice), 1 ether);
    }

    function test_sendEth_revertsIfNotExecutor() public {
        deal(address(treasury), 1 ether);
        vm.prank(attacker);
        vm.expectRevert();
        treasury.sendEth(payable(alice), 0.5 ether);
    }

    function test_sendEth_zeroAmount_succeeds() public {
        deal(address(treasury), 1 ether);
        vm.prank(timelock);
        treasury.sendEth(payable(alice), 0);
        assertEq(alice.balance, 0);
    }

    // ── tokenBalance ─────────────────────────────────────────────────────────

    function test_tokenBalance_returnsCorrectAmount() public {
        token.mint(address(treasury), 777e18);
        assertEq(treasury.tokenBalance(address(token)), 777e18);
    }

    function test_tokenBalance_zeroWhenEmpty() public view {
        assertEq(treasury.tokenBalance(address(token)), 0);
    }
}
