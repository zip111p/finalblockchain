// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IChainlinkAdapter} from "../interfaces/IChainlinkAdapter.sol";

/// @title LendingPool — RWA-collateralized lending built from scratch
/// @dev Linear interest rate model. Users deposit RWA tokens as collateral,
///      borrow a stablecoin up to MAX_LTV. Positions can be liquidated when
///      health factor drops below 1.0.
contract LendingPool is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_LTV = 7000;             // 70% in bps
    uint256 public constant LIQUIDATION_THRESHOLD = 8000; // 80% in bps
    uint256 public constant LIQUIDATION_BONUS = 500;    // 5% bonus
    uint256 public constant BASE_RATE = 2e16;           // 2% per year
    uint256 public constant SLOPE_1 = 10e16;            // 10% per year at optimal
    uint256 public constant SLOPE_2 = 100e16;           // 100% per year above optimal
    uint256 public constant OPTIMAL_UTIL = 8e17;        // 80%

    // ─── State ────────────────────────────────────────────────────────────

    IERC20 public immutable collateralToken;
    IERC20 public immutable borrowToken;
    IChainlinkAdapter public oracle;

    struct Position {
        uint256 collateral;
        uint256 scaledDebt;  // debt / debtIndex at time of borrow
    }

    mapping(address => Position) public positions;

    uint256 public totalCollateral;
    uint256 public totalScaledDebt;
    uint256 public totalLiquidity;   // LP-provided borrow token
    uint256 public debtIndex;        // starts at PRECISION; accumulates interest
    uint256 public lastUpdateTs;

    // ─── Events ───────────────────────────────────────────────────────────

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount, uint256 interestPaid);
    event Liquidated(
        address indexed borrower, address indexed liquidator, uint256 debtCovered, uint256 collateralSeized
    );
    event LiquidityProvided(address indexed provider, uint256 amount);
    event LiquidityWithdrawn(address indexed provider, uint256 amount);
    event OracleUpdated(address newOracle);

    // ─── Constructor ──────────────────────────────────────────────────────

    constructor(IERC20 collateralToken_, IERC20 borrowToken_, IChainlinkAdapter oracle_, address owner_)
        Ownable(owner_)
    {
        collateralToken = collateralToken_;
        borrowToken = borrowToken_;
        oracle = oracle_;
        debtIndex = PRECISION;
        lastUpdateTs = block.timestamp;
    }

    // ─── LP functions ─────────────────────────────────────────────────────

    function provideLiquidity(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Zero amount");
        _accrueInterest();
        // Effects
        totalLiquidity += amount;
        // Interactions
        borrowToken.safeTransferFrom(msg.sender, address(this), amount);
        emit LiquidityProvided(msg.sender, amount);
    }

    function withdrawLiquidity(uint256 amount) external nonReentrant onlyOwner {
        require(amount > 0, "Zero amount");
        require(amount <= availableLiquidity(), "Insufficient free liquidity");
        _accrueInterest();
        // Effects
        totalLiquidity -= amount;
        // Interactions
        borrowToken.safeTransfer(msg.sender, amount);
        emit LiquidityWithdrawn(msg.sender, amount);
    }

    // ─── User functions ───────────────────────────────────────────────────

    /// @notice Deposit RWA tokens as collateral (CEI pattern)
    function depositCollateral(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Zero amount");
        // Checks — none beyond amount > 0
        // Effects
        positions[msg.sender].collateral += amount;
        totalCollateral += amount;
        // Interactions
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralDeposited(msg.sender, amount);
    }

    /// @notice Withdraw collateral while keeping position healthy (CEI pattern)
    function withdrawCollateral(uint256 amount) external nonReentrant whenNotPaused {
        Position storage pos = positions[msg.sender];
        _accrueInterest();
        uint256 currentDebt = _currentDebt(pos.scaledDebt);

        // Checks
        require(pos.collateral >= amount, "Insufficient collateral");
        uint256 remaining = pos.collateral - amount;
        require(_isHealthy(remaining, currentDebt), "Would breach LTV");
        // Effects
        pos.collateral -= amount;
        totalCollateral -= amount;
        // Interactions
        collateralToken.safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount);
    }

    /// @notice Borrow stablecoin against collateral (CEI pattern)
    function borrow(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Zero amount");
        require(amount <= availableLiquidity(), "Insufficient pool liquidity");
        _accrueInterest();

        Position storage pos = positions[msg.sender];
        uint256 currentDebt = _currentDebt(pos.scaledDebt);
        uint256 newDebt = currentDebt + amount;

        // Checks
        require(_isHealthy(pos.collateral, newDebt), "Exceeds max LTV");
        // Effects
        uint256 scaledAmount = (amount * PRECISION) / debtIndex;
        pos.scaledDebt += scaledAmount;
        totalScaledDebt += scaledAmount;
        // Interactions
        borrowToken.safeTransfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    /// @notice Repay debt (CEI pattern)
    function repay(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        _accrueInterest();

        Position storage pos = positions[msg.sender];
        uint256 currentDebt = _currentDebt(pos.scaledDebt);
        require(currentDebt > 0, "No debt");

        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;
        uint256 interestPaid = repayAmount > (pos.scaledDebt * debtIndex / PRECISION)
            ? repayAmount - (pos.scaledDebt * debtIndex / PRECISION)
            : 0;

        // When repaying the full debt, zero out scaledDebt entirely to avoid 1-wei dust
        // from double floor-division rounding in scaledAmount ↔ amount conversions.
        uint256 scaledRepay = (repayAmount >= currentDebt)
            ? pos.scaledDebt
            : (repayAmount * PRECISION) / debtIndex;
        if (scaledRepay > pos.scaledDebt) scaledRepay = pos.scaledDebt;

        // Effects
        pos.scaledDebt -= scaledRepay;
        totalScaledDebt -= scaledRepay;
        // Interactions
        borrowToken.safeTransferFrom(msg.sender, address(this), repayAmount);
        emit Repaid(msg.sender, repayAmount, interestPaid);
    }

    /// @notice Liquidate an unhealthy position (CEI pattern)
    function liquidate(address borrower, uint256 debtToCover) external nonReentrant whenNotPaused {
        _accrueInterest();
        Position storage pos = positions[borrower];
        uint256 currentDebt = _currentDebt(pos.scaledDebt);

        // Checks
        require(!_isHealthy(pos.collateral, currentDebt), "Position is healthy");
        require(debtToCover > 0 && debtToCover <= currentDebt, "Invalid debt amount");

        uint256 price = oracle.getPrice(); // 18-decimal USD price per collateral token
        // collateralSeized = debtToCover / price * (1 + bonus)
        uint256 collateralSeized = (debtToCover * PRECISION * (10000 + LIQUIDATION_BONUS)) / (price * 10000);
        if (collateralSeized > pos.collateral) collateralSeized = pos.collateral;

        uint256 scaledRepay = (debtToCover * PRECISION) / debtIndex;
        if (scaledRepay > pos.scaledDebt) scaledRepay = pos.scaledDebt;

        // Effects
        pos.scaledDebt -= scaledRepay;
        pos.collateral -= collateralSeized;
        totalScaledDebt -= scaledRepay;
        totalCollateral -= collateralSeized;
        // Interactions
        borrowToken.safeTransferFrom(msg.sender, address(this), debtToCover);
        collateralToken.safeTransfer(msg.sender, collateralSeized);

        emit Liquidated(borrower, msg.sender, debtToCover, collateralSeized);
    }

    // ─── View functions ───────────────────────────────────────────────────

    function healthFactor(address user) external view returns (uint256) {
        Position memory pos = positions[user];
        uint256 debt = _currentDebt(pos.scaledDebt);
        if (debt == 0) return type(uint256).max;
        uint256 price = oracle.getPrice();
        uint256 collateralValue = (pos.collateral * price) / PRECISION;
        return (collateralValue * LIQUIDATION_THRESHOLD * PRECISION) / (debt * 10000);
    }

    function currentDebt(address user) external view returns (uint256) {
        uint256 elapsed = block.timestamp - lastUpdateTs;
        uint256 liveIndex = debtIndex;
        if (elapsed > 0) {
            uint256 rate = borrowRate();
            liveIndex += (debtIndex * rate * elapsed) / (365 days * PRECISION);
        }
        return (positions[user].scaledDebt * liveIndex) / PRECISION;
    }

    function utilizationRate() public view returns (uint256) {
        if (totalLiquidity == 0) return 0;
        uint256 totalDebt_ = (totalScaledDebt * debtIndex) / PRECISION;
        return (totalDebt_ * PRECISION) / totalLiquidity;
    }

    function borrowRate() public view returns (uint256) {
        uint256 util = utilizationRate();
        if (util <= OPTIMAL_UTIL) {
            return BASE_RATE + (util * SLOPE_1) / OPTIMAL_UTIL;
        }
        uint256 excess = util - OPTIMAL_UTIL;
        return BASE_RATE + SLOPE_1 + (excess * SLOPE_2) / (PRECISION - OPTIMAL_UTIL);
    }

    function availableLiquidity() public view returns (uint256) {
        uint256 totalDebt_ = (totalScaledDebt * debtIndex) / PRECISION;
        return totalLiquidity > totalDebt_ ? totalLiquidity - totalDebt_ : 0;
    }

    // ─── Admin ────────────────────────────────────────────────────────────

    function setOracle(address newOracle) external onlyOwner {
        oracle = IChainlinkAdapter(newOracle);
        emit OracleUpdated(newOracle);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── Internal ─────────────────────────────────────────────────────────

    function _accrueInterest() internal {
        uint256 elapsed = block.timestamp - lastUpdateTs;
        if (elapsed == 0) return;
        uint256 rate = borrowRate();
        // debtIndex grows by rate * elapsed / 1 year
        uint256 delta = (debtIndex * rate * elapsed) / (365 days * PRECISION);
        debtIndex += delta;
        lastUpdateTs = block.timestamp;
    }

    function _currentDebt(uint256 scaledDebt) internal view returns (uint256) {
        return (scaledDebt * debtIndex) / PRECISION;
    }

    function _isHealthy(uint256 collateral, uint256 debt) internal view returns (bool) {
        if (debt == 0) return true;
        uint256 price = oracle.getPrice();
        uint256 collateralValue = (collateral * price) / PRECISION;
        uint256 maxDebt = (collateralValue * MAX_LTV) / 10000;
        return debt <= maxDebt;
    }
}
