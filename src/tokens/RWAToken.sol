// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title RWAToken V1 — UUPS-upgradeable ERC-20 representing a real-world asset
/// @dev Role-gated minting: only MINTER_ROLE (authorized issuers) can mint/burn
contract RWAToken is
    Initializable,
    ERC20Upgradeable,
    ERC20PausableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @custom:storage-location erc7201:rwa.storage.RWAToken
    struct RWAStorage {
        address backingAsset;
        uint256 reserveRatioBps; // e.g. 10000 = 100% fully backed
        string assetDescription;
    }

    // keccak256(abi.encode(uint256(keccak256("rwa.storage.RWAToken")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RWA_STORAGE_LOCATION =
        0x1234000000000000000000000000000000000000000000000000000000000000;

    function _getRWAStorage() private pure returns (RWAStorage storage $) {
        assembly {
            $.slot := RWA_STORAGE_LOCATION
        }
    }

    event AssetOnboarded(address indexed backingAsset, uint256 reserveRatioBps, string description);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name,
        string memory symbol,
        address admin,
        address backingAsset_,
        uint256 reserveRatioBps_,
        string memory assetDescription_
    ) external initializer {
        __ERC20_init(name, symbol);
        __ERC20Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        RWAStorage storage $ = _getRWAStorage();
        $.backingAsset = backingAsset_;
        $.reserveRatioBps = reserveRatioBps_;
        $.assetDescription = assetDescription_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        emit AssetOnboarded(backingAsset_, reserveRatioBps_, assetDescription_);
    }

    // ─── Issuer functions ─────────────────────────────────────────────────

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyRole(MINTER_ROLE) {
        _burn(from, amount);
    }

    // ─── Admin functions ──────────────────────────────────────────────────

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function setReserveRatio(uint256 newRatioBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRatioBps <= 10000, "Cannot exceed 100%");
        _getRWAStorage().reserveRatioBps = newRatioBps;
    }

    // ─── View functions ───────────────────────────────────────────────────

    function backingAsset() external view returns (address) {
        return _getRWAStorage().backingAsset;
    }

    function reserveRatioBps() external view returns (uint256) {
        return _getRWAStorage().reserveRatioBps;
    }

    function assetDescription() external view returns (string memory) {
        return _getRWAStorage().assetDescription;
    }

    // ─── Required overrides ───────────────────────────────────────────────

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function _update(address from, address to, uint256 value)
        internal
        virtual
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
    {
        super._update(from, to, value);
    }
}
