// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IChainlinkAdapter} from "./IChainlinkAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ChainlinkAdapter — wraps Chainlink price feed + Proof of Reserve feed
/// @dev Implements Oracle Adapter pattern. All external consumers depend on
///      IChainlinkAdapter, never on Chainlink directly — easy to swap in tests.
contract ChainlinkAdapter is IChainlinkAdapter, Ownable {
    uint256 public constant MAX_PRICE_AGE = 3600;   // 1 hour
    uint256 public constant MAX_RESERVE_AGE = 86400; // 24 hours

    AggregatorV3Interface public priceFeed;
    AggregatorV3Interface public proofOfReserveFeed;

    uint256 public stalePriceThreshold;
    uint256 public staleReserveThreshold;

    event PriceFeedUpdated(address indexed oldFeed, address indexed newFeed);
    event ProofOfReserveFeedUpdated(address indexed oldFeed, address indexed newFeed);
    event StalenessThresholdUpdated(uint256 priceThreshold, uint256 reserveThreshold);

    constructor(
        address priceFeed_,
        address proofOfReserveFeed_,
        uint256 stalePriceThreshold_,
        uint256 staleReserveThreshold_,
        address owner_
    ) Ownable(owner_) {
        require(stalePriceThreshold_ <= MAX_PRICE_AGE, "Price threshold too high");
        require(staleReserveThreshold_ <= MAX_RESERVE_AGE, "Reserve threshold too high");
        priceFeed = AggregatorV3Interface(priceFeed_);
        proofOfReserveFeed = AggregatorV3Interface(proofOfReserveFeed_);
        stalePriceThreshold = stalePriceThreshold_;
        staleReserveThreshold = staleReserveThreshold_;
    }

    // ─── IChainlinkAdapter ────────────────────────────────────────────────

    /// @notice Returns asset price normalized to 18 decimals, reverts if stale
    function getPrice() external view override returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();

        require(answer > 0, "ChainlinkAdapter: invalid price");
        require(updatedAt != 0, "ChainlinkAdapter: round not complete");
        require(block.timestamp - updatedAt <= stalePriceThreshold, "ChainlinkAdapter: stale price");
        require(answeredInRound >= roundId, "ChainlinkAdapter: stale round");

        uint8 feedDecimals = priceFeed.decimals();
        return _normalize(uint256(answer), feedDecimals);
    }

    /// @notice Returns proof-of-reserve value normalized to 18 decimals, reverts if stale
    function getProofOfReserve() external view override returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            proofOfReserveFeed.latestRoundData();

        require(answer > 0, "ChainlinkAdapter: invalid reserve");
        require(updatedAt != 0, "ChainlinkAdapter: round not complete");
        require(block.timestamp - updatedAt <= staleReserveThreshold, "ChainlinkAdapter: stale reserve");
        require(answeredInRound >= roundId, "ChainlinkAdapter: stale round");

        uint8 feedDecimals = proofOfReserveFeed.decimals();
        return _normalize(uint256(answer), feedDecimals);
    }

    function decimals() external pure override returns (uint8) {
        return 18;
    }

    // ─── Admin ────────────────────────────────────────────────────────────

    function updatePriceFeed(address newFeed) external onlyOwner {
        emit PriceFeedUpdated(address(priceFeed), newFeed);
        priceFeed = AggregatorV3Interface(newFeed);
    }

    function updateProofOfReserveFeed(address newFeed) external onlyOwner {
        emit ProofOfReserveFeedUpdated(address(proofOfReserveFeed), newFeed);
        proofOfReserveFeed = AggregatorV3Interface(newFeed);
    }

    function updateStalenessThresholds(uint256 priceThreshold, uint256 reserveThreshold) external onlyOwner {
        require(priceThreshold <= MAX_PRICE_AGE, "Price threshold too high");
        require(reserveThreshold <= MAX_RESERVE_AGE, "Reserve threshold too high");
        stalePriceThreshold = priceThreshold;
        staleReserveThreshold = reserveThreshold;
        emit StalenessThresholdUpdated(priceThreshold, reserveThreshold);
    }

    // ─── Internal ─────────────────────────────────────────────────────────

    function _normalize(uint256 value, uint8 feedDecimals) internal pure returns (uint256) {
        if (feedDecimals < 18) {
            return value * 10 ** (18 - feedDecimals);
        } else if (feedDecimals > 18) {
            return value / 10 ** (feedDecimals - 18);
        }
        return value;
    }
}
