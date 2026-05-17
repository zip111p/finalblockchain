// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RWAToken} from "../../src/tokens/RWAToken.sol";
import {RWATokenV2} from "../../src/tokens/RWATokenV2.sol";

contract RWATokenV2Test is Test {
    RWAToken   public impl1;
    RWATokenV2 public impl2;
    ERC1967Proxy public proxy;
    RWAToken   public token;   // V1 view
    RWATokenV2 public tokenV2; // V2 view

    address public admin    = makeAddr("admin");
    address public alice    = makeAddr("alice");
    address public bob      = makeAddr("bob");
    address public feeRecip = makeAddr("feeRecip");

    address constant PRICE_FEED = address(0xdead);

    function setUp() public {
        impl1 = new RWAToken();
        bytes memory init = abi.encodeCall(
            RWAToken.initialize,
            ("US Treasury", "USTB", admin, PRICE_FEED, 10000, "Backed by US Treasuries")
        );
        proxy  = new ERC1967Proxy(address(impl1), init);
        token  = RWAToken(address(proxy));
        tokenV2 = RWATokenV2(address(proxy));

        // Mint some tokens via V1
        vm.prank(admin);
        token.mint(alice, 10_000e18);
    }

    function _upgradeToV2() internal {
        impl2 = new RWATokenV2();
        vm.prank(admin);
        token.upgradeToAndCall(address(impl2), "");
    }

    function _upgradeAndInit(uint256 feeBps) internal {
        _upgradeToV2();
        vm.prank(admin);
        tokenV2.initializeV2(feeBps, feeRecip);
    }

    // ── upgrade ──────────────────────────────────────────────────────────────

    function test_upgrade_adminCanUpgrade() public {
        _upgradeToV2();
        // After upgrade, V2 functions are callable
        vm.prank(admin);
        tokenV2.initializeV2(50, feeRecip);
        assertEq(tokenV2.transferFeeBps(), 50);
    }

    function test_upgrade_nonAdminReverts() public {
        impl2 = new RWATokenV2();
        vm.prank(alice);
        vm.expectRevert();
        token.upgradeToAndCall(address(impl2), "");
    }

    function test_upgrade_preservesV1State() public {
        _upgradeToV2();
        assertEq(token.balanceOf(alice), 10_000e18);
        assertEq(token.name(), "US Treasury");
    }

    // ── initializeV2 ─────────────────────────────────────────────────────────

    function test_initializeV2_setsFeeBps() public {
        _upgradeAndInit(50);
        assertEq(tokenV2.transferFeeBps(), 50);
    }

    function test_initializeV2_setsFeeRecipient() public {
        _upgradeAndInit(50);
        assertEq(tokenV2.feeRecipient(), feeRecip);
    }

    function test_initializeV2_grantsFeeManagerRole() public {
        _upgradeAndInit(50);
        assertTrue(tokenV2.hasRole(tokenV2.FEE_MANAGER_ROLE(), admin));
    }

    function test_initializeV2_grantsWhitelistRole() public {
        _upgradeAndInit(50);
        assertTrue(tokenV2.hasRole(tokenV2.WHITELIST_ROLE(), admin));
    }

    function test_initializeV2_revertsFeeTooHigh() public {
        _upgradeToV2();
        vm.prank(admin);
        vm.expectRevert("Fee exceeds 1%");
        tokenV2.initializeV2(101, feeRecip);
    }

    function test_initializeV2_revertsIfNotAdmin() public {
        _upgradeToV2();
        vm.prank(alice);
        vm.expectRevert();
        tokenV2.initializeV2(10, feeRecip);
    }

    function test_initializeV2_zeroFeeAllowed() public {
        _upgradeAndInit(0);
        assertEq(tokenV2.transferFeeBps(), 0);
    }

    // ── setTransferFee ───────────────────────────────────────────────────────

    function test_setTransferFee_updatesFee() public {
        _upgradeAndInit(50);
        vm.prank(admin);
        tokenV2.setTransferFee(10, feeRecip);
        assertEq(tokenV2.transferFeeBps(), 10);
    }

    function test_setTransferFee_revertsFeeTooHigh() public {
        _upgradeAndInit(50);
        vm.prank(admin);
        vm.expectRevert("Fee exceeds 1%");
        tokenV2.setTransferFee(101, feeRecip);
    }

    function test_setTransferFee_revertsIfNotFeeManager() public {
        _upgradeAndInit(50);
        vm.prank(alice);
        vm.expectRevert();
        tokenV2.setTransferFee(10, feeRecip);
    }

    function test_setTransferFee_emitsEvent() public {
        _upgradeAndInit(50);
        vm.expectEmit(false, false, false, true);
        emit RWATokenV2.TransferFeeSet(10, feeRecip);
        vm.prank(admin);
        tokenV2.setTransferFee(10, feeRecip);
    }

    // ── transfer with fee ────────────────────────────────────────────────────

    function test_transfer_deductsFee() public {
        _upgradeAndInit(100); // 1% fee
        vm.prank(alice);
        tokenV2.transfer(bob, 1000e18);

        uint256 fee = 10e18; // 1% of 1000
        assertEq(tokenV2.balanceOf(bob), 990e18);
        assertEq(tokenV2.balanceOf(feeRecip), fee);
    }

    function test_transfer_noFeeWhenZeroBps() public {
        _upgradeAndInit(0);
        vm.prank(alice);
        tokenV2.transfer(bob, 1000e18);
        assertEq(tokenV2.balanceOf(bob), 1000e18);
        assertEq(tokenV2.balanceOf(feeRecip), 0);
    }

    function test_mint_noFeeApplied() public {
        _upgradeAndInit(100);
        vm.prank(admin);
        token.mint(bob, 500e18);
        // fee not applied on mint (from == address(0))
        assertEq(tokenV2.balanceOf(bob), 500e18);
        assertEq(tokenV2.balanceOf(feeRecip), 0);
    }

    // ── whitelist ────────────────────────────────────────────────────────────

    function test_setWhitelistEnabled_enablesWhitelist() public {
        _upgradeAndInit(0);
        vm.prank(admin);
        tokenV2.setWhitelistEnabled(true);
        // transfer should revert now (neither alice nor bob whitelisted)
        vm.prank(alice);
        vm.expectRevert("Transfer restricted");
        tokenV2.transfer(bob, 100e18);
    }

    function test_setWhitelistEnabled_emitsEvent() public {
        _upgradeAndInit(0);
        vm.expectEmit(false, false, false, true);
        emit RWATokenV2.WhitelistToggled(true);
        vm.prank(admin);
        tokenV2.setWhitelistEnabled(true);
    }

    function test_setWhitelistEnabled_revertsIfNotAdmin() public {
        _upgradeAndInit(0);
        vm.prank(alice);
        vm.expectRevert();
        tokenV2.setWhitelistEnabled(true);
    }

    function test_setWhitelisted_allowsTransfer() public {
        _upgradeAndInit(0);
        vm.prank(admin);
        tokenV2.setWhitelistEnabled(true);
        vm.prank(admin);
        tokenV2.setWhitelisted(alice, true);

        vm.prank(alice);
        tokenV2.transfer(bob, 100e18); // alice is whitelisted sender — succeeds
        assertEq(tokenV2.balanceOf(bob), 100e18);
    }

    function test_setWhitelisted_recipientAllowsTransfer() public {
        _upgradeAndInit(0);
        vm.prank(admin);
        tokenV2.setWhitelistEnabled(true);
        vm.prank(admin);
        tokenV2.setWhitelisted(bob, true);

        vm.prank(alice);
        tokenV2.transfer(bob, 100e18); // bob is whitelisted recipient — succeeds
        assertEq(tokenV2.balanceOf(bob), 100e18);
    }

    function test_setWhitelisted_isWhitelistedReturnsTrue() public {
        _upgradeAndInit(0);
        vm.prank(admin);
        tokenV2.setWhitelisted(alice, true);
        assertTrue(tokenV2.isWhitelisted(alice));
    }

    function test_setWhitelisted_revertsIfNotWhitelistRole() public {
        _upgradeAndInit(0);
        vm.prank(alice);
        vm.expectRevert();
        tokenV2.setWhitelisted(bob, true);
    }

    function test_setWhitelisted_emitsEvent() public {
        _upgradeAndInit(0);
        vm.expectEmit(true, false, false, true);
        emit RWATokenV2.AddressWhitelisted(alice, true);
        vm.prank(admin);
        tokenV2.setWhitelisted(alice, true);
    }

    function test_whitelist_disabledAllowsAllTransfers() public {
        _upgradeAndInit(0);
        // whitelist disabled by default — alice can transfer freely
        vm.prank(alice);
        tokenV2.transfer(bob, 1000e18);
        assertEq(tokenV2.balanceOf(bob), 1000e18);
    }

    // ── view functions ───────────────────────────────────────────────────────

    function test_transferFeeBps_returnsValue() public {
        _upgradeAndInit(75);
        assertEq(tokenV2.transferFeeBps(), 75);
    }

    function test_feeRecipient_returnsAddress() public {
        _upgradeAndInit(50);
        assertEq(tokenV2.feeRecipient(), feeRecip);
    }

    function test_isWhitelisted_falseByDefault() public {
        _upgradeAndInit(0);
        assertFalse(tokenV2.isWhitelisted(alice));
    }
}
