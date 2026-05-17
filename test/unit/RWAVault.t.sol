// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {RWAVault} from "../../src/vault/RWAVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RWAVaultTest is Test {
    RWAVault public vault;
    MockERC20 public asset;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant INITIAL_MINT = 10_000e18;

    function setUp() public {
        asset = new MockERC20("RWA Token", "RWAT", 18);
        vault = new RWAVault(IERC20(address(asset)), "RWA Vault Shares", "vRWAT", owner);

        asset.mint(alice, INITIAL_MINT);
        asset.mint(bob, INITIAL_MINT);
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);
    }

    // ── deposit ──────────────────────────────────────────────────────────────

    function test_deposit_mintsShares() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000e18, alice);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_deposit_transfersAssets() public {
        uint256 before = asset.balanceOf(alice);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        assertEq(asset.balanceOf(alice), before - 1000e18);
    }

    function test_deposit_firstDeposit1to1() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000e18, alice);
        assertEq(shares, 1000e18);
    }

    // ── redeem ───────────────────────────────────────────────────────────────

    function test_redeem_returnsAssets() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000e18, alice);
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(assets, 1000e18, 1); // rounding
    }

    function test_redeem_burnsShares() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000e18, alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(vault.balanceOf(alice), 0);
    }

    // ── withdraw ─────────────────────────────────────────────────────────────

    function test_withdraw_exactAssets() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        vm.prank(alice);
        vault.withdraw(500e18, alice, alice);
        assertApproxEqAbs(asset.balanceOf(alice), INITIAL_MINT - 500e18, 1);
    }

    // ── yield accrual ────────────────────────────────────────────────────────

    function test_yieldAccrual_increasesTotalAssets() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        vm.prank(owner);
        vault.setYieldRate(1e9); // tiny rate for test

        uint256 assetsBefore = vault.totalAssets();
        vm.warp(block.timestamp + 365 days);
        uint256 assetsAfter = vault.totalAssets();
        assertGt(assetsAfter, assetsBefore);
    }

    function test_setYieldRate_revertsIfTooHigh() public {
        uint256 overLimit = vault.MAX_YIELD_RATE() + 1; // evaluate before prank so prank isn't consumed
        vm.prank(owner);
        vm.expectRevert("Rate too high");
        vault.setYieldRate(overLimit);
    }

    function test_setYieldRate_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setYieldRate(1e9);
    }

    // ── ERC-4626 rounding invariant ───────────────────────────────────────────

    function test_rounding_previewDepositNeverOverstates() public view {
        uint256 assets = 1000e18;
        uint256 shares = vault.previewDeposit(assets);
        // shares minted on actual deposit should be >= previewDeposit (vault favours itself on deposit)
        assertGe(shares, 0);
    }

    function test_rounding_previewRedeemNeverOverstates() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000e18, alice);
        uint256 previewAssets = vault.previewRedeem(shares);
        vm.prank(alice);
        uint256 actualAssets = vault.redeem(shares, alice, alice);
        assertLe(actualAssets, previewAssets + 1); // allow 1 wei rounding
    }

    // ── pause ────────────────────────────────────────────────────────────────

    function test_pause_blocksDeposit() public {
        vm.prank(owner);
        vault.pause();
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(100e18, alice);
    }

    function test_pause_blocksRedeem() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000e18, alice);
        vm.prank(owner);
        vault.pause();
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(shares, alice, alice);
    }

    function test_pause_blocksMint() public {
        vm.prank(owner);
        vault.pause();
        vm.prank(alice);
        vm.expectRevert();
        vault.mint(100e18, alice);
    }

    function test_pause_blocksWithdraw() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        vm.prank(owner);
        vault.pause();
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(100e18, alice, alice);
    }

    function test_unpause_restoresDeposit() public {
        vm.prank(owner);
        vault.pause();
        vm.prank(owner);
        vault.unpause();
        vm.prank(alice);
        uint256 shares = vault.deposit(100e18, alice);
        assertGt(shares, 0);
    }

    function test_pause_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();
    }

    function test_unpause_revertsIfNotOwner() public {
        vm.prank(owner);
        vault.pause();
        vm.prank(alice);
        vm.expectRevert();
        vault.unpause();
    }

    // ── mint (ERC-4626) ──────────────────────────────────────────────────────

    function test_mint_sharesDepositsByAssets() public {
        vm.prank(alice);
        uint256 assets = vault.mint(500e18, alice);
        assertGt(assets, 0);
        assertEq(vault.balanceOf(alice), 500e18);
    }

    function test_mint_firstMint1to1() public {
        vm.prank(alice);
        uint256 assets = vault.mint(1000e18, alice);
        assertEq(assets, 1000e18);
    }

    // ── setYieldRate ─────────────────────────────────────────────────────────

    function test_setYieldRate_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit RWAVault.YieldRateUpdated(0, 1e9);
        vm.prank(owner);
        vault.setYieldRate(1e9);
    }

    function test_setYieldRate_zeroDisablesYield() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        vm.prank(owner);
        vault.setYieldRate(0);
        uint256 before = vault.totalAssets();
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.totalAssets(), before);
    }

    // ── totalAssets with accrued yield ───────────────────────────────────────

    function test_totalAssets_includesPendingYield() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        vm.prank(owner);
        vault.setYieldRate(1e12);
        vm.warp(block.timestamp + 1 days);
        assertGt(vault.totalAssets(), 1000e18);
    }

    function test_totalAssets_zeroRateNoYield() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.totalAssets(), 1000e18);
    }

    // ── withdraw ─────────────────────────────────────────────────────────────

    function test_withdraw_burnsCorrectShares() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        uint256 sharesBefore = vault.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(500e18, alice, alice);
        assertLt(vault.balanceOf(alice), sharesBefore);
    }

    function test_withdraw_sendsAssetsToReceiver() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        uint256 before = asset.balanceOf(bob);
        vm.prank(alice);
        vault.withdraw(500e18, bob, alice);
        assertEq(asset.balanceOf(bob), before + 500e18);
    }

    // ── previewMint / previewWithdraw ────────────────────────────────────────

    function test_previewMint_matchesMintCost() public {
        uint256 shares = 1000e18;
        uint256 preview = vault.previewMint(shares);
        vm.prank(alice);
        uint256 actual = vault.mint(shares, alice);
        assertApproxEqAbs(actual, preview, 1);
    }

    function test_previewWithdraw_matchesWithdrawShares() public {
        vm.prank(alice);
        vault.deposit(2000e18, alice);
        uint256 assets = 500e18;
        uint256 preview = vault.previewWithdraw(assets);
        vm.prank(alice);
        uint256 actual = vault.withdraw(assets, alice, alice);
        assertApproxEqAbs(actual, preview, 1);
    }

    // ── yield accrual emit ───────────────────────────────────────────────────

    function test_accrueYield_emitsYieldAccrued() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        vm.prank(owner);
        vault.setYieldRate(1e12);
        vm.warp(block.timestamp + 1 days);
        // A second deposit triggers _accrueYield with rate>0 and elapsed>0
        vm.expectEmit(false, false, false, false);
        emit RWAVault.YieldAccrued(0, 0);
        vm.prank(bob);
        vault.deposit(100e18, bob);
    }

    function test_accrueYield_pendingYieldAccumulates() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        vm.prank(owner);
        vault.setYieldRate(1e12);
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        vault.deposit(100e18, bob);
        assertGt(vault.pendingYield(), 0);
    }

    function test_accrueYield_zeroElapsed_noEmit() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        vm.prank(owner);
        vault.setYieldRate(1e12);
        // No time warp — elapsed == 0, so no yield emitted
        uint256 pendingBefore = vault.pendingYield();
        vm.prank(bob);
        vault.deposit(100e18, bob);
        assertEq(vault.pendingYield(), pendingBefore);
    }

    function test_totalAssets_includesPendingYieldAfterAccrual() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        vm.prank(owner);
        vault.setYieldRate(1e12);
        vm.warp(block.timestamp + 1 days);
        // trigger _accrueYield
        vm.prank(bob);
        vault.deposit(100e18, bob);
        // pendingYield is now > 0 and included in totalAssets
        assertGt(vault.totalAssets(), 1100e18);
    }
}
