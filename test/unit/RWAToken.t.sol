// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RWAToken} from "../../src/tokens/RWAToken.sol";
import {RWATokenV2} from "../../src/tokens/RWATokenV2.sol";

contract RWATokenTest is Test {
    RWAToken public impl;
    RWAToken public token;
    ERC1967Proxy public proxy;

    address public admin = makeAddr("admin");
    address public minter = makeAddr("minter");
    address public user = makeAddr("user");
    address public backing = makeAddr("backing");

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    function setUp() public {
        impl = new RWAToken();
        bytes memory initData = abi.encodeCall(
            RWAToken.initialize,
            ("US Treasury Bond", "USTB", admin, backing, 10000, "10-year US Treasury Note")
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        token = RWAToken(address(proxy));

        vm.prank(admin);
        token.grantRole(MINTER_ROLE, minter);
    }

    // ── initialize ──────────────────────────────────────────────────────────

    function test_initialize_setsName() public view {
        assertEq(token.name(), "US Treasury Bond");
    }

    function test_initialize_setsSymbol() public view {
        assertEq(token.symbol(), "USTB");
    }

    function test_initialize_setsBackingAsset() public view {
        assertEq(token.backingAsset(), backing);
    }

    function test_initialize_setsReserveRatio() public view {
        assertEq(token.reserveRatioBps(), 10000);
    }

    function test_initialize_grantsAdminRole() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_initialize_cannotCallTwice() public {
        vm.expectRevert();
        token.initialize("X", "X", admin, backing, 10000, "desc");
    }

    // ── mint ────────────────────────────────────────────────────────────────

    function test_mint_minterCanMint() public {
        vm.prank(minter);
        token.mint(user, 1000e18);
        assertEq(token.balanceOf(user), 1000e18);
    }

    function test_mint_revertsIfNotMinter() public {
        vm.prank(user);
        vm.expectRevert();
        token.mint(user, 1000e18);
    }

    function test_mint_increasesTotalSupply() public {
        vm.prank(minter);
        token.mint(user, 500e18);
        assertEq(token.totalSupply(), 500e18);
    }

    // ── burn ────────────────────────────────────────────────────────────────

    function test_burn_minterCanBurn() public {
        vm.prank(minter);
        token.mint(user, 1000e18);
        vm.prank(minter);
        token.burn(user, 400e18);
        assertEq(token.balanceOf(user), 600e18);
    }

    function test_burn_revertsIfNotMinter() public {
        vm.prank(minter);
        token.mint(user, 1000e18);
        vm.prank(user);
        vm.expectRevert();
        token.burn(user, 100e18);
    }

    // ── pause ───────────────────────────────────────────────────────────────

    function test_pause_adminCanPause() public {
        vm.prank(admin);
        token.pause();
        assertTrue(token.paused());
    }

    function test_pause_revertsIfNotPauser() public {
        vm.prank(user);
        vm.expectRevert();
        token.pause();
    }

    function test_pause_blocksTransfer() public {
        vm.prank(minter);
        token.mint(user, 100e18);
        vm.prank(admin);
        token.pause();
        vm.prank(user);
        vm.expectRevert();
        token.transfer(minter, 10e18);
    }

    function test_unpause_resumesTransfers() public {
        vm.prank(minter);
        token.mint(user, 100e18);
        vm.prank(admin);
        token.pause();
        vm.prank(admin);
        token.unpause();
        vm.prank(user);
        token.transfer(minter, 10e18);
        assertEq(token.balanceOf(minter), 10e18);
    }

    // ── setReserveRatio ──────────────────────────────────────────────────────

    function test_setReserveRatio_adminCanSet() public {
        vm.prank(admin);
        token.setReserveRatio(9000);
        assertEq(token.reserveRatioBps(), 9000);
    }

    function test_setReserveRatio_revertsAbove100Pct() public {
        vm.prank(admin);
        vm.expectRevert("Cannot exceed 100%");
        token.setReserveRatio(10001);
    }

    // ── UUPS upgrade V1 → V2 ────────────────────────────────────────────────

    function test_upgrade_toV2_works() public {
        RWATokenV2 implV2 = new RWATokenV2();
        vm.prank(admin);
        token.upgradeToAndCall(address(implV2), "");
        RWATokenV2 tokenV2 = RWATokenV2(address(proxy));
        vm.prank(admin);
        tokenV2.initializeV2(50, admin); // 0.5% fee
        assertEq(tokenV2.transferFeeBps(), 50);
    }

    function test_upgrade_revertsIfNotUpgrader() public {
        RWATokenV2 implV2 = new RWATokenV2();
        vm.prank(user);
        vm.expectRevert();
        token.upgradeToAndCall(address(implV2), "");
    }

    function test_upgrade_preservesState() public {
        vm.prank(minter);
        token.mint(user, 1000e18);
        RWATokenV2 implV2 = new RWATokenV2();
        vm.prank(admin);
        token.upgradeToAndCall(address(implV2), "");
        assertEq(RWATokenV2(address(proxy)).balanceOf(user), 1000e18);
    }
}
