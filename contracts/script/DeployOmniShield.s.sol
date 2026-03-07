// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {OmniShieldEscrow} from "../src/OmniShieldEscrow.sol";
import {StealthPayment} from "../src/StealthPayment.sol";
import {StealthVault} from "../src/StealthVault.sol";
import {YieldRouter} from "../src/YieldRouter.sol";
import {OmniShieldHub} from "../src/OmniShieldHub.sol";
import {XcmRouter} from "../src/XcmRouter.sol";
import {CryptoRegistry} from "../src/CryptoRegistry.sol";

/// @title DeployOmniShield
/// @notice Deploys the complete Omni-Shield protocol
/// @dev Run with:
///   source .env && forge script script/DeployOmniShield.s.sol:DeployOmniShield \
///     --rpc-url $POLKADOT_HUB_TESTNET_RPC \
///     --broadcast --skip-simulation -vvvv
///
///   For dry-run (no broadcast):
///   source .env && forge script script/DeployOmniShield.s.sol:DeployOmniShield \
///     --rpc-url $POLKADOT_HUB_TESTNET_RPC --skip-simulation
contract DeployOmniShield is Script {
    // =========================================================================
    // Configuration — override via environment variables
    // =========================================================================

    /// @notice Protocol fee in basis points (default: 50 = 0.5%)
    uint256 public constant DEFAULT_FEE_BPS = 50;

    /// @notice Minimum yield router deposit (0.01 DOT equiv = 10^16 wei)
    uint256 public constant DEFAULT_MIN_DEPOSIT = 0.01 ether;

    // =========================================================================
    // Deploy
    // =========================================================================

    function run() external {
        // Load config from environment
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Fee collector defaults to deployer if not set
        address feeCollector = vm.envOr("FEE_COLLECTOR", deployer);

        // Oracle defaults to deployer for testnet
        address oracle = vm.envOr("ORACLE_ADDRESS", deployer);

        uint256 feeBps = vm.envOr("PROTOCOL_FEE_BPS", DEFAULT_FEE_BPS);
        uint256 minDeposit = vm.envOr("MIN_DEPOSIT", DEFAULT_MIN_DEPOSIT);

        console2.log("=== Omni-Shield Deployment ===");
        console2.log("Deployer:      ", deployer);
        console2.log("Fee Collector:  ", feeCollector);
        console2.log("Oracle:         ", oracle);
        console2.log("Fee (bps):      ", feeBps);
        console2.log("Min Deposit:    ", minDeposit);
        console2.log("==============================");

        vm.startBroadcast(deployerKey);

        // 1. Deploy Escrow
        OmniShieldEscrow escrow = new OmniShieldEscrow(feeCollector, feeBps);
        console2.log("Escrow deployed at:         ", address(escrow));

        // 2. Deploy Stealth Payment
        StealthPayment stealth = new StealthPayment();
        console2.log("StealthPayment deployed at: ", address(stealth));

        // 3. Deploy Yield Router
        YieldRouter router = new YieldRouter(oracle, minDeposit);
        console2.log("YieldRouter deployed at:    ", address(router));

        // 4. Deploy XCM Router (relayer = deployer for testnet)
        address relayer = vm.envOr("RELAYER_ADDRESS", deployer);
        XcmRouter xcmRouter = new XcmRouter(relayer);
        console2.log("XcmRouter deployed at:      ", address(xcmRouter));

        // 5. Wire up XcmRouter ↔ YieldRouter
        xcmRouter.authorizeCaller(address(router));
        router.setXcmRouter(address(xcmRouter));
        console2.log("XcmRouter authorized as YieldRouter's XCM dispatcher");

        // 6. Deploy CryptoRegistry (PVM precompile integration)
        CryptoRegistry cryptoReg = new CryptoRegistry();
        console2.log("CryptoRegistry deployed at:  ", address(cryptoReg));

        // 7. Wire CryptoRegistry into StealthPayment and XcmRouter
        stealth.setCryptoRegistry(address(cryptoReg));
        xcmRouter.setCryptoRegistry(address(cryptoReg));
        cryptoReg.authorizeConsumer(address(stealth));
        console2.log("CryptoRegistry wired into StealthPayment + XcmRouter");

        // 7b. Deploy StealthVault (Day 12-14: complete private payment flow)
        StealthVault stealthVault = new StealthVault(address(stealth));
        console2.log("StealthVault deployed at:    ", address(stealthVault));

        // 8. Deploy Hub (orchestrator)
        OmniShieldHub hub = new OmniShieldHub(
            address(escrow),
            address(stealth),
            address(router),
            address(cryptoReg)
        );
        console2.log("OmniShieldHub deployed at:  ", address(hub));

        // 9. Setup initial yield sources for testnet demo
        _setupTestnetSources(router);

        // 10. Configure parachain beneficiaries for testnet
        _setupParachainBeneficiaries(xcmRouter, deployer);

        vm.stopBroadcast();

        // Log summary
        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("Escrow:          ", address(escrow));
        console2.log("StealthPayment:  ", address(stealth));
        console2.log("StealthVault:    ", address(stealthVault));
        console2.log("YieldRouter:     ", address(router));
        console2.log("XcmRouter:       ", address(xcmRouter));
        console2.log("CryptoRegistry:  ", address(cryptoReg));
        console2.log("OmniShieldHub:   ", address(hub));
        console2.log("===========================");
    }

    /// @notice Add demo yield sources for testnet
    function _setupTestnetSources(YieldRouter router) internal {
        // Bifrost liquid staking — paraId 2030
        router.addYieldSource(
            2030,
            "Bifrost vDOT",
            1200, // 12% APY
            1000 ether // 1000 DOT capacity
        );

        // HydraDX Omnipool — paraId 2034
        router.addYieldSource(
            2034,
            "HydraDX Omnipool",
            850, // 8.5% APY
            5000 ether // 5000 DOT capacity
        );

        // Acala liquid staking — paraId 2000
        router.addYieldSource(
            2000,
            "Acala LDOT",
            950, // 9.5% APY
            2000 ether // 2000 DOT capacity
        );

        console2.log("Testnet yield sources configured (3 sources)");
    }

    /// @notice Configure parachain beneficiaries for XCM routing
    /// @dev Pads deployer's EVM address to bytes32 as default vault address
    function _setupParachainBeneficiaries(XcmRouter xcmRouter, address deployer) internal {
        bytes32 defaultVault = bytes32(uint256(uint160(deployer)));

        // Bifrost (2030) — vDOT vault
        xcmRouter.setParachainBeneficiary(2030, defaultVault);
        xcmRouter.setRouteConfig(2030, 1_000_000_000, 65_536);

        // HydraDX (2034) — Omnipool vault
        xcmRouter.setParachainBeneficiary(2034, defaultVault);
        xcmRouter.setRouteConfig(2034, 1_000_000_000, 65_536);

        // Acala (2000) — LDOT vault
        xcmRouter.setParachainBeneficiary(2000, defaultVault);
        xcmRouter.setRouteConfig(2000, 1_000_000_000, 65_536);

        console2.log("Parachain beneficiaries configured (3 parachains)");
    }
}
