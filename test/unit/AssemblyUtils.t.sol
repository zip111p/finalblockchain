// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {AssemblyUtils, AssemblyUtilsSolidity} from "../../src/utils/AssemblyUtils.sol";

/// @notice Tests + gas benchmark: assembly vs pure Solidity
contract AssemblyUtilsTest is Test {
    // ── bpsOf ────────────────────────────────────────────────────────────────

    function test_bpsOf_assembly_matchesSolidity(uint128 amount, uint16 bps) public pure {
        vm.assume(bps <= 10000);
        assertEq(
            AssemblyUtils.bpsOf(amount, bps),
            AssemblyUtilsSolidity.bpsOf(amount, bps)
        );
    }

    function test_bpsOf_knownValue() public pure {
        assertEq(AssemblyUtils.bpsOf(10000e18, 300), 300e18); // 3%
    }

    function test_bpsOf_zeroBps() public pure {
        assertEq(AssemblyUtils.bpsOf(1000e18, 0), 0);
    }

    // ── min ──────────────────────────────────────────────────────────────────

    function test_min_returnsSmaller(uint256 a, uint256 b) public pure {
        uint256 result = AssemblyUtils.min(a, b);
        assertLe(result, a);
        assertLe(result, b);
        assertTrue(result == a || result == b);
    }

    function test_min_equalInputs() public pure {
        assertEq(AssemblyUtils.min(42, 42), 42);
    }

    // ── max ──────────────────────────────────────────────────────────────────

    function test_max_returnsLarger(uint256 a, uint256 b) public pure {
        uint256 result = AssemblyUtils.max(a, b);
        assertGe(result, a);
        assertGe(result, b);
        assertTrue(result == a || result == b);
    }

    // ── sqrt ─────────────────────────────────────────────────────────────────

    function test_sqrt_zero() public pure {
        assertEq(AssemblyUtils.sqrt(0), 0);
    }

    function test_sqrt_knownValues() public pure {
        assertEq(AssemblyUtils.sqrt(4), 2);
        assertEq(AssemblyUtils.sqrt(9), 3);
        assertEq(AssemblyUtils.sqrt(16), 4);
        assertEq(AssemblyUtils.sqrt(1e18), 1e9);
    }

    function test_sqrt_assembly_matchesSolidity(uint128 x) public pure {
        assertEq(AssemblyUtils.sqrt(x), AssemblyUtilsSolidity.sqrt(x));
    }

    // ── gas benchmark ─────────────────────────────────────────────────────────

    function test_benchmark_bpsOf_assembly() public view {
        uint256 gasBefore = gasleft();
        for (uint256 i = 0; i < 100; i++) {
            AssemblyUtils.bpsOf(1_000_000e18, 300);
        }
        uint256 gasAfter = gasleft();
        console2.log("Assembly bpsOf (100x):", gasBefore - gasAfter, "gas");
    }

    function test_benchmark_bpsOf_solidity() public view {
        uint256 gasBefore = gasleft();
        for (uint256 i = 0; i < 100; i++) {
            AssemblyUtilsSolidity.bpsOf(1_000_000e18, 300);
        }
        uint256 gasAfter = gasleft();
        console2.log("Solidity bpsOf (100x):", gasBefore - gasAfter, "gas");
    }

    // ── eq32 ──────────────────────────────────────────────────────────────────

    function test_eq32_assembly_equalBytes() public pure {
        bytes32 a = keccak256("hello");
        assertTrue(AssemblyUtils.eq32(a, a));
    }

    function test_eq32_assembly_differentBytes() public pure {
        bytes32 a = keccak256("hello");
        bytes32 b = keccak256("world");
        assertFalse(AssemblyUtils.eq32(a, b));
    }

    function test_eq32_assembly_matchesSolidity(bytes32 a, bytes32 b) public pure {
        assertEq(AssemblyUtils.eq32(a, b), AssemblyUtilsSolidity.eq32(a, b));
    }

    // ── Solidity equivalents ──────────────────────────────────────────────────

    function test_min_solidity_returnsSmaller(uint256 a, uint256 b) public pure {
        uint256 result = AssemblyUtilsSolidity.min(a, b);
        assertLe(result, a);
        assertLe(result, b);
    }

    function test_max_solidity_returnsLarger(uint256 a, uint256 b) public pure {
        uint256 result = AssemblyUtilsSolidity.max(a, b);
        assertGe(result, a);
        assertGe(result, b);
    }
}
