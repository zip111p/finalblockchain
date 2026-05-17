// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title RWACertificate — ERC-721 NFT representing legal ownership of a real-world asset
contract RWACertificate is ERC721, ERC721URIStorage, AccessControl, Pausable {
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 private _tokenIdCounter;

    struct CertificateData {
        string assetId;       // off-chain asset identifier
        uint256 faceValue;    // nominal value in USD (18 decimals)
        uint64 issuedAt;
        uint64 expiresAt;     // 0 = no expiry
        bool active;
    }

    mapping(uint256 => CertificateData) public certificates;

    event CertificateIssued(uint256 indexed tokenId, address indexed to, string assetId, uint256 faceValue);
    event CertificateRevoked(uint256 indexed tokenId, string reason);

    constructor(address admin) ERC721("RWA Certificate", "RWACERT") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ISSUER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    function issueCertificate(
        address to,
        string calldata assetId,
        uint256 faceValue,
        uint64 expiresAt,
        string calldata tokenURI_
    ) external onlyRole(ISSUER_ROLE) whenNotPaused returns (uint256 tokenId) {
        tokenId = _tokenIdCounter++;

        certificates[tokenId] = CertificateData({
            assetId: assetId,
            faceValue: faceValue,
            issuedAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            active: true
        });

        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenURI_);

        emit CertificateIssued(tokenId, to, assetId, faceValue);
    }

    function revokeCertificate(uint256 tokenId, string calldata reason) external onlyRole(ISSUER_ROLE) {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        certificates[tokenId].active = false;
        emit CertificateRevoked(tokenId, reason);
    }

    function isValid(uint256 tokenId) external view returns (bool) {
        CertificateData memory cert = certificates[tokenId];
        if (!cert.active) return false;
        if (cert.expiresAt != 0 && block.timestamp > cert.expiresAt) return false;
        return true;
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ─── Required overrides ───────────────────────────────────────────────

    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721URIStorage, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
