// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {RWAFactory} from "../../src/factory/RWAFactory.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract RWAFactoryTest is Test {
    RWAFactory public factory;
    address public admin = makeAddr("admin");
    address public certAdmin = makeAddr("certAdmin");
    address public deployer = makeAddr("deployer");

    bytes32 constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

    function setUp() public {
        factory = new RWAFactory(admin);
        vm.prank(admin);
        factory.grantRole(DEPLOYER_ROLE, deployer);
    }

    // ── deployCertificate (CREATE) ────────────────────────────────────────────

    function test_deployCertificate_returnsNonZeroAddress() public {
        vm.prank(deployer);
        address cert = factory.deployCertificate(certAdmin);
        assertNotEq(cert, address(0));
    }

    function test_deployCertificate_incrementsCount() public {
        assertEq(factory.deployedCount(), 0);
        vm.prank(deployer);
        factory.deployCertificate(certAdmin);
        assertEq(factory.deployedCount(), 1);
    }

    function test_deployCertificate_tracksAddress() public {
        vm.prank(deployer);
        address cert = factory.deployCertificate(certAdmin);
        assertEq(factory.deployedAt(0), cert);
    }

    function test_deployCertificate_revertsIfNotDeployer() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert();
        factory.deployCertificate(certAdmin);
    }

    // ── deployCertificateDeterministic (CREATE2) ──────────────────────────────

    function test_create2_addressMatchesPrediction() public {
        bytes32 salt = keccak256("test-salt");
        address predicted = factory.predictAddress(certAdmin, salt);
        vm.prank(deployer);
        address actual = factory.deployCertificateDeterministic(certAdmin, salt);
        assertEq(actual, predicted);
    }

    function test_create2_revertsIfSaltReused() public {
        bytes32 salt = keccak256("same-salt");
        vm.prank(deployer);
        factory.deployCertificateDeterministic(certAdmin, salt);
        vm.prank(deployer);
        vm.expectRevert("Salt already used");
        factory.deployCertificateDeterministic(certAdmin, salt);
    }

    function test_create2_differentSaltsGiveDifferentAddresses() public {
        bytes32 salt1 = keccak256("salt-1");
        bytes32 salt2 = keccak256("salt-2");
        vm.startPrank(deployer);
        address addr1 = factory.deployCertificateDeterministic(certAdmin, salt1);
        address addr2 = factory.deployCertificateDeterministic(certAdmin, salt2);
        vm.stopPrank();
        assertNotEq(addr1, addr2);
    }

    function test_deployedCertificate_hasCorrectAdmin() public {
        vm.prank(deployer);
        address cert = factory.deployCertificate(certAdmin);
        assertTrue(IAccessControl(cert).hasRole(bytes32(0), certAdmin));
    }
}
