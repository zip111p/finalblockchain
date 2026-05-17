// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RWACertificate} from "../../src/tokens/RWACertificate.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract RWACertificateTest is Test {
    RWACertificate public cert;
    address public admin = makeAddr("admin");
    address public issuer = makeAddr("issuer");
    address public user = makeAddr("user");

    bytes32 constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    function setUp() public {
        cert = new RWACertificate(admin);
        vm.prank(admin);
        cert.grantRole(ISSUER_ROLE, issuer);
    }

    function test_issueCertificate_mintsNFT() public {
        vm.prank(issuer);
        uint256 tokenId = cert.issueCertificate(user, "ASSET-001", 100_000e18, 0, "ipfs://uri");
        assertEq(cert.ownerOf(tokenId), user);
    }

    function test_issueCertificate_storesData() public {
        vm.prank(issuer);
        uint256 tokenId = cert.issueCertificate(user, "ASSET-001", 100_000e18, 0, "ipfs://uri");
        (string memory assetId, uint256 faceValue,, , bool active) = cert.certificates(tokenId);
        assertEq(assetId, "ASSET-001");
        assertEq(faceValue, 100_000e18);
        assertTrue(active);
    }

    function test_issueCertificate_revertsIfNotIssuer() public {
        vm.prank(user);
        vm.expectRevert();
        cert.issueCertificate(user, "ASSET-001", 100_000e18, 0, "ipfs://uri");
    }

    function test_revokeCertificate_marksInactive() public {
        vm.prank(issuer);
        uint256 tokenId = cert.issueCertificate(user, "ASSET-001", 100_000e18, 0, "ipfs://uri");
        vm.prank(issuer);
        cert.revokeCertificate(tokenId, "Compliance violation");
        assertFalse(cert.isValid(tokenId));
    }

    function test_isValid_expiredCertificate() public {
        vm.prank(issuer);
        uint256 tokenId = cert.issueCertificate(user, "ASSET-001", 100_000e18, uint64(block.timestamp + 1 days), "ipfs://uri");
        assertTrue(cert.isValid(tokenId));
        vm.warp(block.timestamp + 2 days);
        assertFalse(cert.isValid(tokenId));
    }

    function test_pause_blocksIssuance() public {
        vm.prank(admin);
        cert.pause();
        vm.prank(issuer);
        vm.expectRevert();
        cert.issueCertificate(user, "ASSET-001", 100_000e18, 0, "ipfs://uri");
    }

    function test_unpause_restoresIssuance() public {
        vm.prank(admin);
        cert.pause();
        vm.prank(admin);
        cert.unpause();
        vm.prank(issuer);
        uint256 tokenId = cert.issueCertificate(user, "ASSET-001", 100_000e18, 0, "ipfs://uri");
        assertEq(cert.ownerOf(tokenId), user);
    }

    function test_tokenURI_returnsStoredURI() public {
        vm.prank(issuer);
        uint256 tokenId = cert.issueCertificate(user, "ASSET-001", 100_000e18, 0, "ipfs://metadata/1");
        assertEq(cert.tokenURI(tokenId), "ipfs://metadata/1");
    }

    function test_supportsInterface_erc721() public view {
        assertTrue(cert.supportsInterface(type(IERC721).interfaceId));
    }

    function test_supportsInterface_accessControl() public view {
        bytes4 accessControlId = type(IAccessControl).interfaceId;
        assertTrue(cert.supportsInterface(accessControlId));
    }

    function test_revokeCertificate_revertsIfTokenDoesNotExist() public {
        vm.prank(issuer);
        vm.expectRevert("Token does not exist");
        cert.revokeCertificate(999, "fraud");
    }

    function test_revokeCertificate_emitsEvent() public {
        vm.prank(issuer);
        uint256 tokenId = cert.issueCertificate(user, "ASSET-002", 50_000e18, 0, "ipfs://uri2");
        vm.expectEmit(true, false, false, true);
        emit RWACertificate.CertificateRevoked(tokenId, "Expired");
        vm.prank(issuer);
        cert.revokeCertificate(tokenId, "Expired");
    }

    function test_isValid_activeNoExpiry() public {
        vm.prank(issuer);
        uint256 tokenId = cert.issueCertificate(user, "ASSET-003", 10_000e18, 0, "ipfs://uri3");
        assertTrue(cert.isValid(tokenId));
    }
}
