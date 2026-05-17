// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LendingPool} from "../../src/lending/LendingPool.sol";
import {MockChainlinkAdapter} from "../mocks/MockChainlinkAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Fork test: use real USDC on mainnet as the borrow token
/// Run with: forge test --fork-url $MAINNET_RPC_URL --match-contract ForkUSDCTest
contract ForkUSDCTest is Test {
    using SafeERC20 for IERC20;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDC_WHALE = 0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503;

    LendingPool public pool;
    MockERC20 public collateral;
    MockChainlinkAdapter public oracle;
    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");

    function setUp() public {
        uint256 mainnetFork = vm.createFork(vm.envString("MAINNET_RPC_URL"));
        vm.selectFork(mainnetFork);

        collateral = new MockERC20("RWA Token", "RWAT", 18);
        oracle = new MockChainlinkAdapter(100e18, 1_000_000e18);
        pool = new LendingPool(collateral, IERC20(USDC), oracle, owner);

        // Fund pool with real USDC from whale
        vm.prank(USDC_WHALE);
        IERC20(USDC).safeTransfer(owner, 1_000_000e6);
        vm.startPrank(owner);
        IERC20(USDC).approve(address(pool), type(uint256).max);
        // USDC has 6 decimals — oracle returns 18-decimal price
        // Adjust liquidity for USDC decimals
        pool.provideLiquidity(100_000e6);
        vm.stopPrank();
    }

    function test_fork_lendingWithRealUSDC_deposit() public {
        collateral.mint(alice, 1000e18);
        vm.prank(alice);
        collateral.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        pool.depositCollateral(1000e18);
        (uint256 col,) = pool.positions(alice);
        assertEq(col, 1000e18);
    }

    function test_fork_usdcBalance_poolHasFunds() public view {
        uint256 bal = IERC20(USDC).balanceOf(address(pool));
        assertGt(bal, 0);
        console2.log("Pool USDC balance:", bal);
    }
}
