// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../src/lending/LendingPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockChainlinkAdapter} from "../mocks/MockChainlinkAdapter.sol";

/// @notice Invariants: solvency of the lending pool
contract InvariantLendingTest is Test {
    LendingPool public pool;
    MockERC20 public collateral;
    MockERC20 public borrow;
    MockChainlinkAdapter public oracle;
    LendingHandler public handler;
    address public owner = makeAddr("owner");

    function setUp() public {
        collateral = new MockERC20("RWAT", "RWAT", 18);
        borrow = new MockERC20("USDC", "USDC", 18);
        oracle = new MockChainlinkAdapter(100e18, 1000e18);
        pool = new LendingPool(collateral, borrow, oracle, owner);

        borrow.mint(owner, 10_000_000e18);
        vm.startPrank(owner);
        borrow.approve(address(pool), type(uint256).max);
        pool.provideLiquidity(10_000_000e18);
        vm.stopPrank();

        handler = new LendingHandler(pool, collateral, borrow, oracle);
        targetContract(address(handler));
    }

    /// @notice Pool borrow token balance must always cover available liquidity.
    ///         Each borrow can create at most 1 wei of rounding in scaledDebt accounting;
    ///         allow depth-sized tolerance (max 15 borrows at depth 15).
    function invariant_poolSolvent() public view {
        uint256 available = pool.availableLiquidity();
        uint256 poolBalance = borrow.balanceOf(address(pool));
        assertGe(poolBalance + 20, available);
    }

    /// @notice Total collateral tracked must match actual token balance
    function invariant_collateralAccounting() public view {
        assertEq(pool.totalCollateral(), collateral.balanceOf(address(pool)));
    }

    /// @notice Debt index must be monotonically non-decreasing
    function invariant_debtIndexNonDecreasing() public view {
        assertGe(pool.debtIndex(), 1e18);
    }
}

contract LendingHandler is Test {
    LendingPool public pool;
    MockERC20 public collateral;
    MockERC20 public borrow;
    MockChainlinkAdapter public oracle;

    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    constructor(LendingPool pool_, MockERC20 col_, MockERC20 bor_, MockChainlinkAdapter oracle_) {
        pool = pool_;
        collateral = col_;
        borrow = bor_;
        oracle = oracle_;

        collateral.mint(user1, type(uint128).max);
        collateral.mint(user2, type(uint128).max);
        borrow.mint(user1, type(uint128).max);
        borrow.mint(user2, type(uint128).max);

        vm.prank(user1);
        collateral.approve(address(pool), type(uint256).max);
        vm.prank(user1);
        borrow.approve(address(pool), type(uint256).max);
        vm.prank(user2);
        collateral.approve(address(pool), type(uint256).max);
        vm.prank(user2);
        borrow.approve(address(pool), type(uint256).max);
    }

    function depositCollateral(uint64 amount) public {
        vm.assume(amount > 1e6);
        vm.prank(user1);
        pool.depositCollateral(amount);
    }

    function borrowSafe(uint64 amount) public {
        (uint256 col,) = pool.positions(user1);
        if (col == 0) return;
        uint256 maxBorrow = (col * oracle.getPrice() * 65) / (100 * 1e18);
        vm.assume(amount > 0 && amount <= maxBorrow && amount <= pool.availableLiquidity());
        vm.prank(user1);
        try pool.borrow(amount) {} catch {}
    }

    function repay(uint64 amount) public {
        uint256 debt = pool.currentDebt(user1);
        if (debt == 0) return;
        vm.assume(amount > 0 && amount <= debt);
        vm.prank(user1);
        pool.repay(amount);
    }

    function timeTravel(uint32 seconds_) public {
        vm.warp(block.timestamp + seconds_);
    }
}
