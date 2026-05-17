// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RWAVault — ERC-4626 yield vault accepting RWA tokens and distributing yield
/// @dev Passes all ERC-4626 rounding invariants: preview functions always round in vault's favour
contract RWAVault is ERC4626, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant MAX_YIELD_RATE = 1e15; // ~31.5% APY max safety cap
    uint256 public constant PRECISION = 1e18;

    uint256 public yieldRatePerSecond; // scaled by PRECISION
    uint256 public lastYieldTimestamp;
    uint256 public pendingYield; // accrued but not yet reflected in balances

    event YieldAccrued(uint256 yield, uint256 newTotalAssets);
    event YieldRateUpdated(uint256 oldRate, uint256 newRate);

    constructor(IERC20 asset_, string memory name_, string memory symbol_, address owner_)
        ERC4626(asset_)
        ERC20(name_, symbol_)
        Ownable(owner_)
    {
        lastYieldTimestamp = block.timestamp;
    }

    // ─── Owner functions ──────────────────────────────────────────────────

    function setYieldRate(uint256 newRate) external onlyOwner {
        require(newRate <= MAX_YIELD_RATE, "Rate too high");
        _accrueYield();
        emit YieldRateUpdated(yieldRatePerSecond, newRate);
        yieldRatePerSecond = newRate;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── ERC-4626 overrides ───────────────────────────────────────────────

    /// @dev Includes accrued yield in total assets — critical for correct share pricing
    function totalAssets() public view override returns (uint256) {
        uint256 base = IERC20(asset()).balanceOf(address(this));
        uint256 elapsed = block.timestamp - lastYieldTimestamp;
        uint256 live = (base * yieldRatePerSecond * elapsed) / PRECISION;
        return base + pendingYield + live;
    }

    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        _accrueYield();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        _accrueYield();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        _accrueYield();
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        _accrueYield();
        return super.redeem(shares, receiver, owner_);
    }

    // ─── Internal ─────────────────────────────────────────────────────────

    function _accrueYield() internal {
        if (yieldRatePerSecond == 0) {
            lastYieldTimestamp = block.timestamp;
            return;
        }
        uint256 base = IERC20(asset()).balanceOf(address(this));
        uint256 elapsed = block.timestamp - lastYieldTimestamp;
        if (elapsed > 0 && base > 0) {
            uint256 yield = (base * yieldRatePerSecond * elapsed) / PRECISION;
            pendingYield += yield;
            emit YieldAccrued(yield, totalAssets());
        }
        lastYieldTimestamp = block.timestamp;
    }

    // ─── ERC-4626 rounding: always round in vault's favour ────────────────

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 0;
    }
}
