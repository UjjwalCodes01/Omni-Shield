// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {StealthPayment} from "../src/StealthPayment.sol";

/// @title E2EStealth
/// @notice End-to-end stealth payment on testnet:
///   1. Register stealth meta-address
///   2. Send native DOT to a stealth address
///   3. Withdraw from the stealth address
///   4. Verify balances at every step
contract E2EStealth is Script {
    StealthPayment constant stealth =
        StealthPayment(payable(0x98DB1edC0ED10888d559C641F709A364818B0167));

    address constant NATIVE = address(0);

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Derive a deterministic "recipient" key-pair for the demo.
        // In production the recipient would be a separate user.
        uint256 recipientKey = uint256(keccak256(abi.encodePacked("e2e-recipient", deployerKey)));
        address recipient = vm.addr(recipientKey);

        console2.log("============================================================");
        console2.log("Omni-Shield E2E Stealth Payment Demo");
        console2.log("============================================================");
        console2.log("Deployer (sender):", deployer);
        console2.log("Recipient:        ", recipient);

        // --- Step 0: Pre-flight ---
        uint256 countBefore = stealth.getAnnouncementCount();
        console2.log("\n[0] Announcement count before:", countBefore);

        // --- Step 1: Register stealth meta-address (if not already) ---
        // Use deterministic key material as stand-in public keys (x-coords).
        bytes32 spendPub = keccak256(abi.encodePacked("spend-pub", deployer));
        bytes32 viewPub  = keccak256(abi.encodePacked("view-pub",  deployer));

        vm.startBroadcast(deployerKey);

        // Only register if not already registered
        StealthPayment.StealthMetaAddress memory existing = stealth.getStealthMetaAddress(deployer);
        if (!existing.isRegistered) {
            stealth.registerStealthMetaAddress(spendPub, viewPub);
            console2.log("[1] Registered stealth meta-address");
        } else {
            console2.log("[1] Already registered, skipping");
        }

        // --- Step 2: Compute a "stealth address" ---
        // In production this comes from ECDH. For the on-chain demo we derive
        // deterministically so we can also withdraw.
        // We'll use the recipientKey as the stealth private key.
        address stealthAddr = recipient; // vm.addr(recipientKey)

        // Ephemeral public key (stand-in x-coord)
        bytes32 ephPub = keccak256(abi.encodePacked("ephemeral", block.timestamp, deployer));
        uint8 viewTag = uint8(uint256(keccak256(abi.encodePacked(ephPub, viewPub))) % 256);

        // --- Step 3: Send 0.001 DOT to stealth address ---
        uint256 sendAmount = 0.001 ether;
        console2.log("\n[2] Sending", sendAmount, "wei to stealth address", stealthAddr);

        stealth.sendNativeToStealth{value: sendAmount}(
            stealthAddr,
            ephPub,
            viewTag,
            "" // no extra metadata
        );

        vm.stopBroadcast();

        // --- Step 4: Verify balance on-chain ---
        uint256 stealthBal = stealth.getStealthBalance(stealthAddr, NATIVE);
        console2.log("[3] Stealth balance after send:", stealthBal, "wei");
        require(stealthBal >= sendAmount, "Balance mismatch after send");

        uint256 countAfter = stealth.getAnnouncementCount();
        console2.log("[4] Announcement count after: ", countAfter);
        require(countAfter == countBefore + 1, "Announcement count mismatch");

        // --- Step 5: Withdraw as the stealth address holder ---
        console2.log("\n[5] Withdrawing to recipient via stealth private key...");

        // Fund the stealth address with a tiny amount for gas
        vm.startBroadcast(deployerKey);
        (bool ok,) = stealthAddr.call{value: 0.0005 ether}("");
        require(ok, "Gas funding failed");
        vm.stopBroadcast();

        uint256 recipientBalBefore = recipient.balance;

        vm.startBroadcast(recipientKey);
        stealth.withdrawFromStealth(NATIVE, recipient);
        vm.stopBroadcast();

        uint256 recipientBalAfter = recipient.balance;
        console2.log("[6] Recipient balance before:", recipientBalBefore);
        console2.log("    Recipient balance after: ", recipientBalAfter);
        require(recipientBalAfter > recipientBalBefore, "Withdraw did not increase balance");

        // Stealth balance should be zero now
        uint256 finalBal = stealth.getStealthBalance(stealthAddr, NATIVE);
        console2.log("[7] Stealth balance after withdraw:", finalBal, "wei");
        require(finalBal == 0, "Stealth balance should be zero");

        console2.log("\n============================================================");
        console2.log("  END-TO-END STEALTH PAYMENT: SUCCESS");
        console2.log("============================================================");
    }
}
