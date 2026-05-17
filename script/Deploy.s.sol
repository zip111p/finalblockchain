// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {RWAToken} from "../src/tokens/RWAToken.sol";
import {GovernanceToken} from "../src/tokens/GovernanceToken.sol";
import {RWACertificate} from "../src/tokens/RWACertificate.sol";
import {RWAVault} from "../src/vault/RWAVault.sol";
import {LendingPool} from "../src/lending/LendingPool.sol";
import {ChainlinkAdapter} from "../src/oracle/ChainlinkAdapter.sol";
import {RWAFactory} from "../src/factory/RWAFactory.sol";
import {RWAGovernor} from "../src/governance/RWAGovernor.sol";
import {Treasury} from "../src/governance/Treasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @notice Idempotent deployment script for the RWA Tokenization Platform
/// Usage: forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
contract DeployScript is Script {
    // ─── Config (override via env vars) ──────────────────────────────────────
    address deployer;
    address priceFeed;
    address proofOfReserveFeed;
    address borrowTokenAddress; // stablecoin on target network
    string rwaName;
    string rwaSymbol;

    // ─── Deployed addresses ───────────────────────────────────────────────────
    GovernanceToken public govToken;
    RWAToken public rwaImpl;
    ERC1967Proxy public rwaProxy;
    RWAToken public rwaToken;
    RWACertificate public certificate;
    RWAVault public vault;
    LendingPool public lendingPool;
    ChainlinkAdapter public oracle;
    RWAFactory public factory;
    TimelockController public timelock;
    RWAGovernor public governor;
    Treasury public treasury;

    function run() external {
        deployer = vm.envAddress("DEPLOYER_ADDRESS");
        priceFeed = vm.envAddress("PRICE_FEED_ADDRESS");
        proofOfReserveFeed = vm.envAddress("POR_FEED_ADDRESS");
        borrowTokenAddress = vm.envAddress("BORROW_TOKEN_ADDRESS");
        rwaName = vm.envOr("RWA_NAME", string("US Treasury Bond Token"));
        rwaSymbol = vm.envOr("RWA_SYMBOL", string("USTB"));

        vm.startBroadcast(deployer);

        // 1. Governance token
        govToken = new GovernanceToken(deployer);
        console2.log("GovernanceToken:", address(govToken));

        // 2. Timelock — default 2-day delay per spec; override with TIMELOCK_DELAY env var for testnet
        uint256 timelockDelay = vm.envOr("TIMELOCK_DELAY", uint256(2 days));
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = deployer;
        executors[0] = address(0);
        timelock = new TimelockController(timelockDelay, proposers, executors, deployer);
        console2.log("TimelockController:", address(timelock));

        // 3. Governor — default spec: 1-day delay, 1-week period; override with env vars for testnet
        uint48 votingDelay  = uint48(vm.envOr("VOTING_DELAY",  uint256(1 days)));
        uint32 votingPeriod = uint32(vm.envOr("VOTING_PERIOD", uint256(1 weeks)));
        uint256 proposalThreshold = govToken.MAX_SUPPLY() / 100; // 1%
        governor = new RWAGovernor(IVotes(address(govToken)), timelock, proposalThreshold, votingDelay, votingPeriod);
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        console2.log("RWAGovernor:", address(governor));

        // 4. Treasury (controlled by Timelock)
        treasury = new Treasury(address(timelock));
        console2.log("Treasury:", address(treasury));

        // 5. Chainlink Oracle adapter
        oracle = new ChainlinkAdapter(priceFeed, proofOfReserveFeed, 3600, 86400, deployer);
        console2.log("ChainlinkAdapter:", address(oracle));

        // 6. RWA Token (UUPS proxy)
        rwaImpl = new RWAToken();
        bytes memory initData = abi.encodeCall(
            RWAToken.initialize,
            (rwaName, rwaSymbol, deployer, priceFeed, 10000, "Real-world asset tokenized on-chain")
        );
        rwaProxy = new ERC1967Proxy(address(rwaImpl), initData);
        rwaToken = RWAToken(address(rwaProxy));
        console2.log("RWAToken (proxy):", address(rwaProxy));
        console2.log("RWAToken (impl):", address(rwaImpl));

        // 7. RWA Certificate NFT
        certificate = new RWACertificate(deployer);
        console2.log("RWACertificate:", address(certificate));

        // 8. ERC-4626 Vault
        vault = new RWAVault(IERC20(address(rwaToken)), "RWA Vault Shares", string.concat("v", rwaSymbol), deployer);
        console2.log("RWAVault:", address(vault));

        // 9. Lending pool
        lendingPool = new LendingPool(IERC20(address(rwaToken)), IERC20(borrowTokenAddress), oracle, deployer);
        console2.log("LendingPool:", address(lendingPool));

        // 10. Factory
        factory = new RWAFactory(deployer);
        console2.log("RWAFactory:", address(factory));

        // 11. Mint initial governance tokens to deployer before relinquishing ownership
        //     2% of MAX_SUPPLY (2 × proposalThreshold) so deployer can create proposals
        govToken.mint(deployer, govToken.MAX_SUPPLY() / 50);
        govToken.delegate(deployer); // self-delegate so voting power is active immediately

        // 12. Transfer admin controls to Timelock
        govToken.transferOwnership(address(timelock));
        vault.transferOwnership(address(timelock));
        lendingPool.transferOwnership(address(timelock));

        vm.stopBroadcast();

        // Print summary
        console2.log("\n=== DEPLOYMENT SUMMARY ===");
        console2.log("Network chain ID:", block.chainid);
        console2.log("GovernanceToken:", address(govToken));
        console2.log("RWAToken proxy:", address(rwaProxy));
        console2.log("RWACertificate:", address(certificate));
        console2.log("RWAVault:", address(vault));
        console2.log("LendingPool:", address(lendingPool));
        console2.log("ChainlinkAdapter:", address(oracle));
        console2.log("RWAFactory:", address(factory));
        console2.log("TimelockController:", address(timelock));
        console2.log("RWAGovernor:", address(governor));
        console2.log("Treasury:", address(treasury));
    }
}
