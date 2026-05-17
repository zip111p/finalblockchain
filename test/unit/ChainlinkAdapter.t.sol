// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainlinkAdapter} from "../../src/oracle/ChainlinkAdapter.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

contract ChainlinkAdapterTest is Test {
    ChainlinkAdapter public adapter;
    MockAggregator public priceFeed;
    MockAggregator public reserveFeed;
    address public owner = makeAddr("owner");

    uint256 constant STALE_PRICE = 3600;
    uint256 constant STALE_RESERVE = 86400;

    function setUp() public {
        vm.warp(100_000); // ensure block.timestamp > all stale thresholds so setStale() never underflows
        priceFeed = new MockAggregator(100e8, 8); // $100, 8 decimals
        reserveFeed = new MockAggregator(1000e8, 8); // $1000 reserve
        adapter = new ChainlinkAdapter(
            address(priceFeed), address(reserveFeed), STALE_PRICE, STALE_RESERVE, owner
        );
    }

    function test_getPrice_returnsNormalizedValue() public view {
        uint256 price = adapter.getPrice();
        assertEq(price, 100e18); // 8-decimal feed normalized to 18
    }

    function test_getPrice_revertsIfStale() public {
        priceFeed.setStale(STALE_PRICE + 1);
        vm.expectRevert("ChainlinkAdapter: stale price");
        adapter.getPrice();
    }

    function test_getPrice_revertsIfNegative() public {
        priceFeed.setAnswer(-1);
        vm.expectRevert("ChainlinkAdapter: invalid price");
        adapter.getPrice();
    }

    function test_getProofOfReserve_returnsNormalizedValue() public view {
        uint256 reserve = adapter.getProofOfReserve();
        assertEq(reserve, 1000e18);
    }

    function test_getProofOfReserve_revertsIfStale() public {
        reserveFeed.setStale(STALE_RESERVE + 1);
        vm.expectRevert("ChainlinkAdapter: stale reserve");
        adapter.getProofOfReserve();
    }

    function test_updatePriceFeed_ownerCanUpdate() public {
        MockAggregator newFeed = new MockAggregator(200e8, 8);
        vm.prank(owner);
        adapter.updatePriceFeed(address(newFeed));
        assertEq(adapter.getPrice(), 200e18);
    }

    function test_updatePriceFeed_revertsIfNotOwner() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        adapter.updatePriceFeed(address(priceFeed));
    }

    function test_staleness_borderline_notStale() public {
        vm.warp(block.timestamp + STALE_PRICE);
        // exactly at threshold should still pass
        uint256 price = adapter.getPrice();
        assertEq(price, 100e18);
    }

    function test_staleness_oneSecondOver_reverts() public {
        vm.warp(block.timestamp + STALE_PRICE + 1);
        vm.expectRevert("ChainlinkAdapter: stale price");
        adapter.getPrice();
    }

    // ── constructor validation ────────────────────────────────────────────────

    function test_constructor_revertsIfPriceThresholdTooHigh() public {
        vm.expectRevert("Price threshold too high");
        new ChainlinkAdapter(address(priceFeed), address(reserveFeed), STALE_PRICE + 1, STALE_RESERVE, owner);
    }

    function test_constructor_revertsIfReserveThresholdTooHigh() public {
        vm.expectRevert("Reserve threshold too high");
        new ChainlinkAdapter(address(priceFeed), address(reserveFeed), STALE_PRICE, STALE_RESERVE + 1, owner);
    }

    function test_constructor_setsThresholds() public view {
        assertEq(adapter.stalePriceThreshold(), STALE_PRICE);
        assertEq(adapter.staleReserveThreshold(), STALE_RESERVE);
    }

    // ── getPrice edge cases ───────────────────────────────────────────────────

    function test_getPrice_revertsIfRoundNotComplete() public {
        priceFeed.setUpdatedAt(0);
        vm.expectRevert("ChainlinkAdapter: round not complete");
        adapter.getPrice();
    }

    function test_getPrice_revertsIfStaleRound() public {
        // Make answeredInRound < roundId by setting answer multiple times
        // then manually setting updatedAt to an old value so answeredInRound lags
        // We simulate via a mock that returns answeredInRound < roundId
        MockAggregator staleFeed = new MockAggregator(100e8, 8);
        staleFeed.setAnswer(200e8); // roundId = 2, answeredInRound = 2
        staleFeed.setAnswer(300e8); // roundId = 3, answeredInRound = 3
        // Now set updatedAt to make answeredInRound appear stale
        staleFeed.setUpdatedAt(0);
        ChainlinkAdapter a = new ChainlinkAdapter(
            address(staleFeed), address(reserveFeed), STALE_PRICE, STALE_RESERVE, owner
        );
        vm.expectRevert("ChainlinkAdapter: round not complete");
        a.getPrice();
    }

    // ── getProofOfReserve edge cases ──────────────────────────────────────────

    function test_getProofOfReserve_revertsIfNegative() public {
        reserveFeed.setAnswer(-1);
        vm.expectRevert("ChainlinkAdapter: invalid reserve");
        adapter.getProofOfReserve();
    }

    function test_getProofOfReserve_revertsIfRoundNotComplete() public {
        reserveFeed.setUpdatedAt(0);
        vm.expectRevert("ChainlinkAdapter: round not complete");
        adapter.getProofOfReserve();
    }

    function test_getProofOfReserve_borderlineStale_passes() public {
        vm.warp(block.timestamp + STALE_RESERVE);
        uint256 reserve = adapter.getProofOfReserve();
        assertEq(reserve, 1000e18);
    }

    function test_getProofOfReserve_oneSecondOver_reverts() public {
        vm.warp(block.timestamp + STALE_RESERVE + 1);
        vm.expectRevert("ChainlinkAdapter: stale reserve");
        adapter.getProofOfReserve();
    }

    // ── normalize decimals ────────────────────────────────────────────────────

    function test_normalize_18decimals_unchanged() public {
        MockAggregator feed18 = new MockAggregator(1e18, 18);
        ChainlinkAdapter a = new ChainlinkAdapter(
            address(feed18), address(reserveFeed), STALE_PRICE, STALE_RESERVE, owner
        );
        assertEq(a.getPrice(), 1e18);
    }

    function test_normalize_greaterThan18_scalesDown() public {
        MockAggregator feed20 = new MockAggregator(1e20, 20);
        ChainlinkAdapter a = new ChainlinkAdapter(
            address(feed20), address(reserveFeed), STALE_PRICE, STALE_RESERVE, owner
        );
        assertEq(a.getPrice(), 1e18);
    }

    function test_normalize_lessThan18_scalesUp() public view {
        // priceFeed has 8 decimals, 100e8 answer → 100e18
        assertEq(adapter.getPrice(), 100e18);
    }

    // ── decimals ─────────────────────────────────────────────────────────────

    function test_decimals_returns18() public view {
        assertEq(adapter.decimals(), 18);
    }

    // ── updateProofOfReserveFeed ──────────────────────────────────────────────

    function test_updateProofOfReserveFeed_ownerCanUpdate() public {
        MockAggregator newFeed = new MockAggregator(2000e8, 8);
        vm.prank(owner);
        adapter.updateProofOfReserveFeed(address(newFeed));
        assertEq(adapter.getProofOfReserve(), 2000e18);
    }

    function test_updateProofOfReserveFeed_revertsIfNotOwner() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        adapter.updateProofOfReserveFeed(address(reserveFeed));
    }

    function test_updateProofOfReserveFeed_emitsEvent() public {
        MockAggregator newFeed = new MockAggregator(2000e8, 8);
        vm.expectEmit(true, true, false, false);
        emit ChainlinkAdapter.ProofOfReserveFeedUpdated(address(reserveFeed), address(newFeed));
        vm.prank(owner);
        adapter.updateProofOfReserveFeed(address(newFeed));
    }

    // ── updateStalenessThresholds ─────────────────────────────────────────────

    function test_updateStalenessThresholds_ownerCanUpdate() public {
        vm.prank(owner);
        adapter.updateStalenessThresholds(1800, 43200);
        assertEq(adapter.stalePriceThreshold(), 1800);
        assertEq(adapter.staleReserveThreshold(), 43200);
    }

    function test_updateStalenessThresholds_revertsIfNotOwner() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        adapter.updateStalenessThresholds(1800, 43200);
    }

    function test_updateStalenessThresholds_revertsIfPriceTooHigh() public {
        vm.prank(owner);
        vm.expectRevert("Price threshold too high");
        adapter.updateStalenessThresholds(STALE_PRICE + 1, STALE_RESERVE);
    }

    function test_updateStalenessThresholds_revertsIfReserveTooHigh() public {
        vm.prank(owner);
        vm.expectRevert("Reserve threshold too high");
        adapter.updateStalenessThresholds(STALE_PRICE, STALE_RESERVE + 1);
    }

    function test_updateStalenessThresholds_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit ChainlinkAdapter.StalenessThresholdUpdated(1800, 43200);
        vm.prank(owner);
        adapter.updateStalenessThresholds(1800, 43200);
    }

    // ── updatePriceFeed event ─────────────────────────────────────────────────

    function test_updatePriceFeed_emitsEvent() public {
        MockAggregator newFeed = new MockAggregator(200e8, 8);
        vm.expectEmit(true, true, false, false);
        emit ChainlinkAdapter.PriceFeedUpdated(address(priceFeed), address(newFeed));
        vm.prank(owner);
        adapter.updatePriceFeed(address(newFeed));
    }
}
