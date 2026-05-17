// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RWAToken} from "./RWAToken.sol";

/// @title RWAToken V2 — adds per-transfer fee and whitelist capability
/// @dev V1 → V2 upgrade: new storage appended after V1 storage (no collision)
/// Storage layout proof: V2 only adds new variables AFTER the inherited V1 layout.
contract RWATokenV2 is RWAToken {
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant WHITELIST_ROLE = keccak256("WHITELIST_ROLE");

    /// @custom:storage-location erc7201:rwa.storage.RWATokenV2
    struct V2Storage {
        uint256 transferFeeBps; // max 100 (1%)
        address feeRecipient;
        bool whitelistEnabled;
        mapping(address => bool) whitelist;
    }

    bytes32 private constant V2_STORAGE_LOCATION =
        0x5678000000000000000000000000000000000000000000000000000000000000;

    function _getV2Storage() private pure returns (V2Storage storage $) {
        assembly {
            $.slot := V2_STORAGE_LOCATION
        }
    }

    event TransferFeeSet(uint256 feeBps, address recipient);
    event WhitelistToggled(bool enabled);
    event AddressWhitelisted(address indexed account, bool status);

    /// @notice Called once after upgrade to initialize V2-specific state
    function initializeV2(uint256 feeBps, address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(feeBps <= 100, "Fee exceeds 1%");
        V2Storage storage $ = _getV2Storage();
        $.transferFeeBps = feeBps;
        $.feeRecipient = recipient;
        _grantRole(FEE_MANAGER_ROLE, msg.sender);
        _grantRole(WHITELIST_ROLE, msg.sender);
        emit TransferFeeSet(feeBps, recipient);
    }

    function setTransferFee(uint256 feeBps, address recipient) external onlyRole(FEE_MANAGER_ROLE) {
        require(feeBps <= 100, "Fee exceeds 1%");
        V2Storage storage $ = _getV2Storage();
        $.transferFeeBps = feeBps;
        $.feeRecipient = recipient;
        emit TransferFeeSet(feeBps, recipient);
    }

    function setWhitelistEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _getV2Storage().whitelistEnabled = enabled;
        emit WhitelistToggled(enabled);
    }

    function setWhitelisted(address account, bool status) external onlyRole(WHITELIST_ROLE) {
        _getV2Storage().whitelist[account] = status;
        emit AddressWhitelisted(account, status);
    }

    function isWhitelisted(address account) external view returns (bool) {
        return _getV2Storage().whitelist[account];
    }

    function transferFeeBps() external view returns (uint256) {
        return _getV2Storage().transferFeeBps;
    }

    function feeRecipient() external view returns (address) {
        return _getV2Storage().feeRecipient;
    }

    function _update(address from, address to, uint256 value) internal override {
        V2Storage storage $ = _getV2Storage();

        if ($.whitelistEnabled && from != address(0) && to != address(0)) {
            require($.whitelist[from] || $.whitelist[to], "Transfer restricted");
        }

        if ($.transferFeeBps > 0 && from != address(0) && to != address(0) && $.feeRecipient != address(0)) {
            uint256 fee = (value * $.transferFeeBps) / 10000;
            super._update(from, $.feeRecipient, fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}
