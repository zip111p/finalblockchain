// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RWACertificate} from "../tokens/RWACertificate.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title RWAFactory — deploys RWACertificate contracts via CREATE and CREATE2
/// @dev Factory pattern: centralised deployment registry with deterministic addressing
contract RWAFactory is AccessControl {
    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

    address[] private _deployed;
    mapping(bytes32 => address) public saltToAddress;

    event DeployedViaCreate(address indexed cert, address indexed admin, uint256 index);
    event DeployedViaCreate2(address indexed cert, address indexed admin, bytes32 salt);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(DEPLOYER_ROLE, admin);
    }

    // ─── CREATE deployment (sequential, non-deterministic) ────────────────

    function deployCertificate(address certAdmin) external onlyRole(DEPLOYER_ROLE) returns (address cert) {
        cert = address(new RWACertificate(certAdmin));
        _deployed.push(cert);
        emit DeployedViaCreate(cert, certAdmin, _deployed.length - 1);
    }

    // ─── CREATE2 deployment (deterministic address) ───────────────────────

    function deployCertificateDeterministic(address certAdmin, bytes32 salt)
        external
        onlyRole(DEPLOYER_ROLE)
        returns (address cert)
    {
        require(saltToAddress[salt] == address(0), "Salt already used");
        cert = address(new RWACertificate{salt: salt}(certAdmin));
        saltToAddress[salt] = cert;
        _deployed.push(cert);
        emit DeployedViaCreate2(cert, certAdmin, salt);
    }

    // ─── Address prediction (CREATE2) ─────────────────────────────────────

    function predictAddress(address certAdmin, bytes32 salt) external view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(abi.encodePacked(type(RWACertificate).creationCode, abi.encode(certAdmin)))
            )
        );
        return address(uint160(uint256(hash)));
    }

    // ─── View ─────────────────────────────────────────────────────────────

    function deployedAt(uint256 index) external view returns (address) {
        return _deployed[index];
    }

    function deployedCount() external view returns (uint256) {
        return _deployed.length;
    }
}
