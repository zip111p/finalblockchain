// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {RWAGovernor} from "../src/governance/RWAGovernor.sol";
import {GovernanceToken} from "../src/tokens/GovernanceToken.sol";

/// @notice Post-deployment verification: checks ownership, Timelock delay, Governor params
/// Usage: forge script script/Verify.s.sol --rpc-url $RPC_URL
contract VerifyScript is Script {
    function run() external view {
        address timelockAddr = vm.envAddress("TIMELOCK_ADDRESS");
        address governorAddr = vm.envAddress("GOVERNOR_ADDRESS");
        address govTokenAddr = vm.envAddress("GOV_TOKEN_ADDRESS");
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");

        TimelockController timelock = TimelockController(payable(timelockAddr));
        RWAGovernor governor = RWAGovernor(payable(governorAddr));
        GovernanceToken govToken = GovernanceToken(govTokenAddr);

        console2.log("=== POST-DEPLOYMENT VERIFICATION ===");

        // Timelock delay
        uint256 minDelay = timelock.getMinDelay();
        console2.log("Timelock min delay (seconds):", minDelay);
        require(minDelay == 2 days, "FAIL: Timelock delay != 2 days");
        console2.log("PASS: Timelock delay = 2 days");

        // Governor params
        console2.log("Governor voting delay:", governor.votingDelay());
        require(governor.votingDelay() == 1 days, "FAIL: voting delay != 1 day");
        console2.log("PASS: Voting delay = 1 day");

        console2.log("Governor voting period:", governor.votingPeriod());
        require(governor.votingPeriod() == 1 weeks, "FAIL: voting period != 1 week");
        console2.log("PASS: Voting period = 1 week");

        // Governor token
        console2.log("GovToken owner:", govToken.owner());
        require(govToken.owner() == timelockAddr, "FAIL: GovToken owner != Timelock");
        console2.log("PASS: GovToken owned by Timelock");

        // Proposer role
        bool governorIsProposer = timelock.hasRole(timelock.PROPOSER_ROLE(), governorAddr);
        require(governorIsProposer, "FAIL: Governor missing PROPOSER_ROLE");
        console2.log("PASS: Governor has PROPOSER_ROLE on Timelock");

        console2.log("\n=== ALL CHECKS PASSED ===");
    }
}
