// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Treasury — protocol treasury controlled exclusively by the Timelock (DAO)
/// @dev Only the EXECUTOR_ROLE (granted to TimelockController) can move funds.
///      Pull-over-push payment pattern: recipients claim funds rather than receiving them.
contract Treasury is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    // ─── Pull-over-push payment model ────────────────────────────────────
    mapping(address => mapping(address => uint256)) public claimable; // token → recipient → amount

    event FundsAllocated(address indexed token, address indexed recipient, uint256 amount);
    event FundsClaimed(address indexed token, address indexed recipient, uint256 amount);
    event EtherReceived(address indexed sender, uint256 amount);

    constructor(address timelockController) {
        _grantRole(DEFAULT_ADMIN_ROLE, timelockController);
        _grantRole(EXECUTOR_ROLE, timelockController);
    }

    receive() external payable {
        emit EtherReceived(msg.sender, msg.value);
    }

    /// @notice Allocate ERC-20 tokens for a recipient to claim (pull-over-push)
    function allocate(address token, address recipient, uint256 amount) external onlyRole(EXECUTOR_ROLE) {
        require(recipient != address(0), "Zero recipient");
        require(amount > 0, "Zero amount");
        claimable[token][recipient] += amount;
        emit FundsAllocated(token, recipient, amount);
    }

    /// @notice Recipient claims their allocated tokens (CEI pattern)
    function claim(address token) external nonReentrant {
        uint256 amount = claimable[token][msg.sender];
        require(amount > 0, "Nothing to claim");
        // Effects before interaction
        claimable[token][msg.sender] = 0;
        // Interaction
        IERC20(token).safeTransfer(msg.sender, amount);
        emit FundsClaimed(token, msg.sender, amount);
    }

    /// @notice Direct ETH transfer via call{value:} (no transfer/send)
    function sendEth(address payable recipient, uint256 amount) external nonReentrant onlyRole(EXECUTOR_ROLE) {
        require(recipient != address(0), "Zero recipient");
        require(address(this).balance >= amount, "Insufficient balance");
        (bool success,) = recipient.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    function tokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
