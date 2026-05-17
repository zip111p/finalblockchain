// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GovernanceToken} from "../../src/tokens/GovernanceToken.sol";

contract GovernanceTokenTest is Test {
    GovernanceToken public token;
    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        token = new GovernanceToken(owner);
    }

    function test_mint_ownerCanMint() public {
        vm.prank(owner);
        token.mint(alice, 1000e18);
        assertEq(token.balanceOf(alice), 1000e18);
    }

    function test_mint_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.mint(alice, 1000e18);
    }

    function test_mint_revertsAboveMaxSupply() public {
        uint256 overLimit = token.MAX_SUPPLY() + 1; // evaluate before prank so prank isn't consumed
        vm.prank(owner);
        vm.expectRevert("Exceeds max supply");
        token.mint(alice, overLimit);
    }

    function test_permit_allowsDelegatedSpend() public {
        vm.prank(owner);
        token.mint(alice, 1000e18);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(alice, address(this), 500e18, deadline);

        token.permit(alice, address(this), 500e18, deadline, v, r, s);
        assertEq(token.allowance(alice, address(this)), 500e18);
    }

    function test_votes_delegateSelf() public {
        vm.prank(owner);
        token.mint(alice, 1000e18);
        vm.prank(alice);
        token.delegate(alice);
        assertEq(token.getVotes(alice), 1000e18);
    }

    function test_votes_delegateToOther() public {
        vm.prank(owner);
        token.mint(alice, 1000e18);
        vm.prank(alice);
        token.delegate(bob);
        assertEq(token.getVotes(bob), 1000e18);
        assertEq(token.getVotes(alice), 0);
    }

    function test_votes_checkpoints() public {
        vm.prank(owner);
        token.mint(alice, 500e18);
        vm.prank(alice);
        token.delegate(alice);
        uint256 blockAfterMint = block.number;
        vm.roll(block.number + 1);
        vm.prank(owner);
        token.mint(alice, 500e18);
        // past votes at blockAfterMint should be 500e18
        assertEq(token.getPastVotes(alice, blockAfterMint), 500e18);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _signPermit(address owner_, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 digest = _permitDigest(owner_, spender, value, token.nonces(owner_), deadline);
        uint256 pk = uint256(keccak256(abi.encodePacked("alice")));
        (v, r, s) = vm.sign(pk, digest);
    }

    function _permitDigest(address owner_, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        owner_,
                        spender,
                        value,
                        nonce,
                        deadline
                    )
                )
            )
        );
    }
}
