// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title AssemblyUtils — gas-optimized math using inline Yul assembly
/// @dev Each function is benchmarked against a Solidity equivalent in test/unit/AssemblyUtils.t.sol
library AssemblyUtils {
    /// @notice Compute basis-point fraction: (amount * bps) / 10000
    function bpsOf(uint256 amount, uint256 bps) internal pure returns (uint256 result) {
        assembly {
            // overflow-safe because bps <= 10000 and amount fits uint256
            result := div(mul(amount, bps), 10000)
        }
    }

    /// @notice Branchless min
    function min(uint256 a, uint256 b) internal pure returns (uint256 result) {
        assembly {
            // if b < a: result = b XOR (a XOR b) = a; else result = a
            result := xor(a, mul(xor(a, b), lt(b, a)))
        }
    }

    /// @notice Branchless max
    function max(uint256 a, uint256 b) internal pure returns (uint256 result) {
        assembly {
            result := xor(a, mul(xor(a, b), gt(b, a)))
        }
    }

    /// @notice Integer square root (Babylonian / Newton's method)
    function sqrt(uint256 x) internal pure returns (uint256 z) {
        assembly {
            switch x
            case 0 { z := 0 }
            default {
                z := x
                let y := add(div(x, 2), 1)
                for {} lt(y, z) {} {
                    z := y
                    y := div(add(div(x, y), y), 2)
                }
            }
        }
    }

    /// @notice Packed bytes32 equality (cheaper than keccak for short strings)
    function eq32(bytes32 a, bytes32 b) internal pure returns (bool result) {
        assembly {
            result := eq(a, b)
        }
    }
}

/// @title AssemblyUtilsSolidity — pure-Solidity equivalents for gas benchmarking
library AssemblyUtilsSolidity {
    function bpsOf(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps) / 10000;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = x / 2 + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }

    function eq32(bytes32 a, bytes32 b) internal pure returns (bool) {
        return a == b;
    }
}
