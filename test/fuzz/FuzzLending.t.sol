// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../src/lending/LendingPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockChainlinkAdapter} from "../mocks/MockChainlinkAdapter.sol";

contract FuzzLendingTest is Test {
    LendingPool public pool;
    MockERC20 public collateral;
    MockERC20 public borrow;
    MockChainlinkAdapter public oracle;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");

    uint256 constant PRICE = 100e18;

    function setUp() public {
        collateral = new MockERC20("RWAT", "RWAT", 18);
        borrow = new MockERC20("USDC", "USDC", 18);
        oracle = new MockChainlinkAdapter(PRICE, PRICE * 10);
        pool = new LendingPool(collateral, borrow, oracle, owner);

        borrow.mint(owner, 10_000_000e18);
        vm.startPrank(owner);
        borrow.approve(address(pool), type(uint256).max);
        pool.provideLiquidity(10_000_000e18);
        vm.stopPrank();

        collateral.mint(alice, type(uint128).max);
        vm.prank(alice);
        collateral.approve(address(pool), type(uint256).max);
        borrow.mint(alice, type(uint128).max);
        vm.prank(alice);
        borrow.approve(address(pool), type(uint256).max);
    }

    /// @notice borrow within max LTV should never revert
    function testFuzz_borrow_withinLTV_succeeds(uint64 collAmt, uint16 borrowPct) public {
        vm.assume(collAmt > 1e6);
        vm.assume(borrowPct <= 6900); // stay safely under 70% LTV

        vm.prank(alice);
        pool.depositCollateral(collAmt);

        uint256 collValue = (uint256(collAmt) * PRICE) / 1e18;
        uint256 borrowAmt = (collValue * borrowPct) / 10000;
        vm.assume(borrowAmt > 0 && borrowAmt <= pool.availableLiquidity());

        vm.prank(alice);
        pool.borrow(borrowAmt);
        assertGt(pool.currentDebt(alice), 0);
    }

    /// @notice repay full debt should always result in zero debt
    function testFuzz_repay_fullDebt_clearsDebt(uint64 collAmt) public {
        vm.assume(collAmt > 1e6);
        vm.prank(alice);
        pool.depositCollateral(collAmt);

        uint256 collValue = (uint256(collAmt) * PRICE) / 1e18;
        uint256 borrowAmt = collValue * 60 / 100; // 60% LTV
        vm.assume(borrowAmt > 0 && borrowAmt <= pool.availableLiquidity());

        vm.prank(alice);
        pool.borrow(borrowAmt);

        // Warp 1 year to accrue interest
        vm.warp(block.timestamp + 365 days);

        uint256 debt = pool.currentDebt(alice);
        vm.prank(alice);
        pool.repay(debt);
        assertEq(pool.currentDebt(alice), 0);
    }

    /// @notice health factor should always be > 1 after borrow at 65% LTV
    function testFuzz_healthFactor_aboveOne_at65pctLTV(uint64 collAmt) public {
        vm.assume(collAmt > 1e6);
        vm.prank(alice);
        pool.depositCollateral(collAmt);

        uint256 collValue = (uint256(collAmt) * PRICE) / 1e18;
        uint256 borrowAmt = collValue * 65 / 100;
        vm.assume(borrowAmt > 0 && borrowAmt <= pool.availableLiquidity());

        vm.prank(alice);
        pool.borrow(borrowAmt);

        uint256 hf = pool.healthFactor(alice);
        assertGt(hf, 1e18);
    }
}
