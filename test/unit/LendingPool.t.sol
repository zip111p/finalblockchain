// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {LendingPool} from "../../src/lending/LendingPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockChainlinkAdapter} from "../mocks/MockChainlinkAdapter.sol";

contract LendingPoolTest is Test {
    LendingPool public pool;
    MockERC20 public collateral;
    MockERC20 public borrowToken;
    MockChainlinkAdapter public oracle;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public liquidator = makeAddr("liquidator");

    // collateral price = $100 (18 decimals)
    uint256 constant PRICE = 100e18;
    uint256 constant POOL_LIQUIDITY = 100_000e18;

    function setUp() public {
        collateral = new MockERC20("RWA Token", "RWAT", 18);
        borrowToken = new MockERC20("USD Stablecoin", "USDC", 18);
        oracle = new MockChainlinkAdapter(PRICE, PRICE * 10);

        pool = new LendingPool(collateral, borrowToken, oracle, owner);

        // Fund pool with liquidity
        borrowToken.mint(owner, POOL_LIQUIDITY);
        vm.startPrank(owner);
        borrowToken.approve(address(pool), POOL_LIQUIDITY);
        pool.provideLiquidity(POOL_LIQUIDITY);
        vm.stopPrank();

        // Give alice collateral
        collateral.mint(alice, 1000e18);
        vm.prank(alice);
        collateral.approve(address(pool), type(uint256).max);

        // Give liquidator borrow tokens
        borrowToken.mint(liquidator, 100_000e18);
        vm.prank(liquidator);
        borrowToken.approve(address(pool), type(uint256).max);
    }

    // ── depositCollateral ────────────────────────────────────────────────────

    function test_depositCollateral_increasesBalance() public {
        vm.prank(alice);
        pool.depositCollateral(100e18);
        (uint256 col,) = pool.positions(alice);
        assertEq(col, 100e18);
    }

    function test_depositCollateral_revertsZero() public {
        vm.prank(alice);
        vm.expectRevert("Zero amount");
        pool.depositCollateral(0);
    }

    function test_depositCollateral_pullsTokens() public {
        uint256 before = collateral.balanceOf(alice);
        vm.prank(alice);
        pool.depositCollateral(100e18);
        assertEq(collateral.balanceOf(alice), before - 100e18);
    }

    // ── borrow ────────────────────────────────────────────────────────────────

    function test_borrow_withinLTV() public {
        vm.prank(alice);
        pool.depositCollateral(100e18);
        // 100 tokens * $100 = $10,000 collateral value
        // max borrow = $10,000 * 70% = $7,000
        vm.prank(alice);
        pool.borrow(7000e18);
        assertEq(borrowToken.balanceOf(alice), 7000e18);
    }

    function test_borrow_revertsAboveLTV() public {
        vm.prank(alice);
        pool.depositCollateral(100e18);
        vm.prank(alice);
        vm.expectRevert("Exceeds max LTV");
        pool.borrow(7001e18);
    }

    function test_borrow_revertsZero() public {
        vm.prank(alice);
        vm.expectRevert("Zero amount");
        pool.borrow(0);
    }

    function test_borrow_revertsInsufficientLiquidity() public {
        collateral.mint(alice, 100_000_000e18);
        vm.prank(alice);
        collateral.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        pool.depositCollateral(100_000_000e18);
        vm.prank(alice);
        vm.expectRevert("Insufficient pool liquidity");
        pool.borrow(POOL_LIQUIDITY + 1);
    }

    // ── repay ─────────────────────────────────────────────────────────────────

    function test_repay_reducesDebt() public {
        vm.prank(alice);
        pool.depositCollateral(100e18);
        vm.prank(alice);
        pool.borrow(5000e18);

        borrowToken.mint(alice, 5000e18);
        vm.prank(alice);
        borrowToken.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        pool.repay(2000e18);

        uint256 debt = pool.currentDebt(alice);
        assertApproxEqAbs(debt, 3000e18, 1e15); // allow tiny interest accrual
    }

    function test_repay_fullDebtClearsPosition() public {
        vm.prank(alice);
        pool.depositCollateral(100e18);
        vm.prank(alice);
        pool.borrow(1000e18);

        borrowToken.mint(alice, 100e18); // extra for interest
        vm.prank(alice);
        borrowToken.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        pool.repay(type(uint256).max); // repay everything
        assertEq(pool.currentDebt(alice), 0);
    }

    // ── withdrawCollateral ────────────────────────────────────────────────────

    function test_withdrawCollateral_withNoDebt() public {
        vm.prank(alice);
        pool.depositCollateral(100e18);
        vm.prank(alice);
        pool.withdrawCollateral(100e18);
        (uint256 col,) = pool.positions(alice);
        assertEq(col, 0);
    }

    function test_withdrawCollateral_revertsBreachesLTV() public {
        vm.prank(alice);
        pool.depositCollateral(100e18);
        vm.prank(alice);
        pool.borrow(6000e18);
        vm.prank(alice);
        vm.expectRevert("Would breach LTV");
        pool.withdrawCollateral(20e18); // would drop collateral value below LTV threshold
    }

    // ── liquidate ─────────────────────────────────────────────────────────────

    function test_liquidate_revertsIfHealthy() public {
        vm.prank(alice);
        pool.depositCollateral(100e18);
        vm.prank(alice);
        pool.borrow(5000e18);
        vm.prank(liquidator);
        vm.expectRevert("Position is healthy");
        pool.liquidate(alice, 1000e18);
    }

    function test_liquidate_succeedsWhenUnhealthy() public {
        vm.prank(alice);
        pool.depositCollateral(100e18);
        vm.prank(alice);
        pool.borrow(6900e18); // close to max LTV

        // Drop price to make position unhealthy
        oracle.setPrice(80e18); // collateral drops 20%

        uint256 debtToCover = 1000e18;
        vm.prank(liquidator);
        pool.liquidate(alice, debtToCover);

        uint256 remainingDebt = pool.currentDebt(alice);
        assertLt(remainingDebt, 6900e18);
    }

    // ── healthFactor ──────────────────────────────────────────────────────────

    function test_healthFactor_maxWithNoDebt() public {
        vm.prank(alice);
        pool.depositCollateral(100e18);
        assertEq(pool.healthFactor(alice), type(uint256).max);
    }

    function test_healthFactor_calculatesCorrectly() public {
        vm.prank(alice);
        pool.depositCollateral(100e18);
        vm.prank(alice);
        pool.borrow(5000e18);
        // collateral value = 100 * 100 = 10000, liqThreshold 80%, debt 5000
        // HF = (10000 * 0.8 * 1e18) / 5000 = 1.6e18
        uint256 hf = pool.healthFactor(alice);
        assertApproxEqRel(hf, 1.6e18, 0.01e18);
    }

    // ── pause ─────────────────────────────────────────────────────────────────

    function test_pause_blocksDeposit() public {
        vm.prank(owner);
        pool.pause();
        vm.prank(alice);
        vm.expectRevert();
        pool.depositCollateral(100e18);
    }
}
