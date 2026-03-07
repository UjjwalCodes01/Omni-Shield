// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {StealthPayment} from "../src/StealthPayment.sol";
import {IStealthPayment} from "../src/interfaces/IStealthPayment.sol";

/// @title StealthPaymentTest
/// @notice Comprehensive test suite for the Stealth Payment contract
contract StealthPaymentTest is Test {
    StealthPayment public stealth;

    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public attacker = makeAddr("attacker");

    // Test keys (not real crypto — just for testing the contract logic)
    bytes32 public constant ALICE_SPENDING_KEY = keccak256("alice-spending");
    bytes32 public constant ALICE_VIEWING_KEY = keccak256("alice-viewing");
    bytes32 public constant BOB_SPENDING_KEY = keccak256("bob-spending");
    bytes32 public constant BOB_VIEWING_KEY = keccak256("bob-viewing");
    bytes32 public constant EPHEMERAL_PUB_KEY = keccak256("ephemeral-1");

    // Stealth address (simulated — in production derived from ECDH)
    address public stealthAddr1 = makeAddr("stealth-1");
    address public stealthAddr2 = makeAddr("stealth-2");

    event StealthMetaAddressRegistered(address indexed registrant, bytes32 spendingPubKey, bytes32 viewingPubKey);

    event Announcement(
        uint256 indexed schemeId,
        address indexed stealthAddress,
        address indexed caller,
        bytes32 ephemeralPubKey,
        bytes metadata
    );

    event StealthPaymentSent(
        address indexed stealthAddress,
        bytes32 indexed ephemeralPubKey,
        address token,
        uint256 amount,
        uint8 viewTag
    );

    event StealthWithdrawal(address indexed stealthAddress, address indexed to, address token, uint256 amount);

    function setUp() public {
        stealth = new StealthPayment();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(attacker, 10 ether);
    }

    // =========================================================================
    // Registry Tests
    // =========================================================================

    function test_register_success() public {
        vm.prank(alice);
        stealth.registerStealthMetaAddress(ALICE_SPENDING_KEY, ALICE_VIEWING_KEY);

        IStealthPayment.StealthMetaAddress memory meta = stealth.getStealthMetaAddress(alice);
        assertTrue(meta.isRegistered);
        assertEq(meta.spendingPubKey, ALICE_SPENDING_KEY);
        assertEq(meta.viewingPubKey, ALICE_VIEWING_KEY);
    }

    function test_register_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit StealthMetaAddressRegistered(alice, ALICE_SPENDING_KEY, ALICE_VIEWING_KEY);

        vm.prank(alice);
        stealth.registerStealthMetaAddress(ALICE_SPENDING_KEY, ALICE_VIEWING_KEY);
    }

    function test_register_revertAlreadyRegistered() public {
        vm.prank(alice);
        stealth.registerStealthMetaAddress(ALICE_SPENDING_KEY, ALICE_VIEWING_KEY);

        vm.prank(alice);
        vm.expectRevert(IStealthPayment.AlreadyRegistered.selector);
        stealth.registerStealthMetaAddress(ALICE_SPENDING_KEY, ALICE_VIEWING_KEY);
    }

    function test_register_revertZeroSpendingKey() public {
        vm.prank(alice);
        vm.expectRevert(IStealthPayment.InvalidPubKey.selector);
        stealth.registerStealthMetaAddress(bytes32(0), ALICE_VIEWING_KEY);
    }

    function test_register_revertZeroViewingKey() public {
        vm.prank(alice);
        vm.expectRevert(IStealthPayment.InvalidPubKey.selector);
        stealth.registerStealthMetaAddress(ALICE_SPENDING_KEY, bytes32(0));
    }

    function test_update_success() public {
        vm.prank(alice);
        stealth.registerStealthMetaAddress(ALICE_SPENDING_KEY, ALICE_VIEWING_KEY);

        bytes32 newSpending = keccak256("new-spending");
        bytes32 newViewing = keccak256("new-viewing");

        vm.prank(alice);
        stealth.updateStealthMetaAddress(newSpending, newViewing);

        IStealthPayment.StealthMetaAddress memory meta = stealth.getStealthMetaAddress(alice);
        assertEq(meta.spendingPubKey, newSpending);
        assertEq(meta.viewingPubKey, newViewing);
    }

    function test_update_revertNotRegistered() public {
        vm.prank(alice);
        vm.expectRevert(IStealthPayment.NotRegistered.selector);
        stealth.updateStealthMetaAddress(ALICE_SPENDING_KEY, ALICE_VIEWING_KEY);
    }

    // =========================================================================
    // Send Native Tests
    // =========================================================================

    function test_sendNative_success() public {
        vm.prank(alice);
        stealth.sendNativeToStealth{value: 1 ether}(stealthAddr1, EPHEMERAL_PUB_KEY, 0xAB, "");

        assertEq(stealth.getStealthBalance(stealthAddr1, address(0)), 1 ether);
        assertTrue(stealth.isStealthAddressUsed(stealthAddr1));
        assertEq(stealth.getAnnouncementCount(), 1);
    }

    function test_sendNative_emitsAnnouncement() public {
        vm.expectEmit(true, true, true, true);
        emit Announcement(0, stealthAddr1, alice, EPHEMERAL_PUB_KEY, "");

        vm.prank(alice);
        stealth.sendNativeToStealth{value: 1 ether}(stealthAddr1, EPHEMERAL_PUB_KEY, 0xAB, "");
    }

    function test_sendNative_emitsPaymentSent() public {
        vm.expectEmit(true, true, true, true);
        emit StealthPaymentSent(stealthAddr1, EPHEMERAL_PUB_KEY, address(0), 1 ether, 0xAB);

        vm.prank(alice);
        stealth.sendNativeToStealth{value: 1 ether}(stealthAddr1, EPHEMERAL_PUB_KEY, 0xAB, "");
    }

    function test_sendNative_revertZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(IStealthPayment.InvalidStealthAddress.selector);
        stealth.sendNativeToStealth{value: 1 ether}(address(0), EPHEMERAL_PUB_KEY, 0xAB, "");
    }

    function test_sendNative_revertZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IStealthPayment.InvalidAmount.selector);
        stealth.sendNativeToStealth{value: 0}(stealthAddr1, EPHEMERAL_PUB_KEY, 0xAB, "");
    }

    function test_sendNative_revertZeroEphemeralKey() public {
        vm.prank(alice);
        vm.expectRevert(IStealthPayment.InvalidPubKey.selector);
        stealth.sendNativeToStealth{value: 1 ether}(stealthAddr1, bytes32(0), 0xAB, "");
    }

    function test_sendNative_multiplePaymentsSameAddress() public {
        vm.startPrank(alice);
        stealth.sendNativeToStealth{value: 1 ether}(stealthAddr1, EPHEMERAL_PUB_KEY, 0xAB, "");
        stealth.sendNativeToStealth{value: 2 ether}(stealthAddr1, keccak256("ephemeral-2"), 0xCD, "");
        vm.stopPrank();

        assertEq(stealth.getStealthBalance(stealthAddr1, address(0)), 3 ether);
        assertEq(stealth.getAnnouncementCount(), 2);
    }

    function test_sendNative_withMetadata() public {
        bytes memory metadata = abi.encode("payment for services", uint256(123));

        vm.prank(alice);
        stealth.sendNativeToStealth{value: 1 ether}(stealthAddr1, EPHEMERAL_PUB_KEY, 0xAB, metadata);

        assertEq(stealth.getStealthBalance(stealthAddr1, address(0)), 1 ether);
    }

    function test_sendNative_revertWhenPaused() public {
        stealth.pause();

        vm.prank(alice);
        vm.expectRevert();
        stealth.sendNativeToStealth{value: 1 ether}(stealthAddr1, EPHEMERAL_PUB_KEY, 0xAB, "");
    }

    // =========================================================================
    // Withdraw Tests
    // =========================================================================

    function test_withdraw_success() public {
        // Send to stealth
        vm.prank(alice);
        stealth.sendNativeToStealth{value: 5 ether}(stealthAddr1, EPHEMERAL_PUB_KEY, 0xAB, "");

        // Withdraw from stealth (msg.sender must be the stealth address)
        address finalDest = makeAddr("final-destination");
        uint256 destBalBefore = finalDest.balance;

        vm.prank(stealthAddr1);
        stealth.withdrawFromStealth(address(0), finalDest);

        assertEq(finalDest.balance, destBalBefore + 5 ether);
        assertEq(stealth.getStealthBalance(stealthAddr1, address(0)), 0);
    }

    function test_withdraw_emitsEvent() public {
        vm.prank(alice);
        stealth.sendNativeToStealth{value: 5 ether}(stealthAddr1, EPHEMERAL_PUB_KEY, 0xAB, "");

        address finalDest = makeAddr("final-dest");

        vm.expectEmit(true, true, true, true);
        emit StealthWithdrawal(stealthAddr1, finalDest, address(0), 5 ether);

        vm.prank(stealthAddr1);
        stealth.withdrawFromStealth(address(0), finalDest);
    }

    function test_withdraw_revertInsufficientBalance() public {
        vm.prank(stealthAddr1);
        vm.expectRevert(IStealthPayment.InsufficientBalance.selector);
        stealth.withdrawFromStealth(address(0), alice);
    }

    function test_withdraw_revertZeroDestination() public {
        vm.prank(alice);
        stealth.sendNativeToStealth{value: 1 ether}(stealthAddr1, EPHEMERAL_PUB_KEY, 0xAB, "");

        vm.prank(stealthAddr1);
        vm.expectRevert(IStealthPayment.InvalidStealthAddress.selector);
        stealth.withdrawFromStealth(address(0), address(0));
    }

    function test_withdraw_cannotWithdrawOthers() public {
        vm.prank(alice);
        stealth.sendNativeToStealth{value: 5 ether}(stealthAddr1, EPHEMERAL_PUB_KEY, 0xAB, "");

        // Attacker tries to withdraw from stealthAddr1
        vm.prank(attacker);
        vm.expectRevert(IStealthPayment.InsufficientBalance.selector);
        stealth.withdrawFromStealth(address(0), attacker);

        // Balance is still intact
        assertEq(stealth.getStealthBalance(stealthAddr1, address(0)), 5 ether);
    }

    function test_withdraw_cantWithdrawTwice() public {
        vm.prank(alice);
        stealth.sendNativeToStealth{value: 5 ether}(stealthAddr1, EPHEMERAL_PUB_KEY, 0xAB, "");

        address dest = makeAddr("dest");
        vm.prank(stealthAddr1);
        stealth.withdrawFromStealth(address(0), dest);

        // Second withdrawal should fail
        vm.prank(stealthAddr1);
        vm.expectRevert(IStealthPayment.InsufficientBalance.selector);
        stealth.withdrawFromStealth(address(0), dest);
    }

    // =========================================================================
    // Receive Test
    // =========================================================================

    function test_receive_revertDirectTransfer() public {
        vm.prank(alice);
        vm.expectRevert("Use sendNativeToStealth");
        (bool success,) = address(stealth).call{value: 1 ether}("");
        success; // silence unused warning
    }

    // =========================================================================
    // Admin Tests
    // =========================================================================

    function test_pause_unpause() public {
        stealth.pause();
        assertTrue(stealth.paused());

        stealth.unpause();
        assertFalse(stealth.paused());
    }

    function test_pause_revertNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        stealth.pause();
    }

    // =========================================================================
    // Fuzz Tests
    // =========================================================================

    function testFuzz_sendAndWithdraw_noValueLeak(uint256 amount) public {
        amount = bound(amount, 1 wei, 1_000_000 ether);
        vm.deal(alice, amount);

        vm.prank(alice);
        stealth.sendNativeToStealth{value: amount}(stealthAddr1, EPHEMERAL_PUB_KEY, 0xAB, "");

        assertEq(stealth.getStealthBalance(stealthAddr1, address(0)), amount);

        address dest = makeAddr("fuzz-dest");
        uint256 destBefore = dest.balance;

        vm.prank(stealthAddr1);
        stealth.withdrawFromStealth(address(0), dest);

        assertEq(dest.balance, destBefore + amount);
        assertEq(stealth.getStealthBalance(stealthAddr1, address(0)), 0);
    }

    function testFuzz_register_anyKeys(bytes32 spending, bytes32 viewing) public {
        vm.assume(spending != bytes32(0) && viewing != bytes32(0));

        vm.prank(alice);
        stealth.registerStealthMetaAddress(spending, viewing);

        IStealthPayment.StealthMetaAddress memory meta = stealth.getStealthMetaAddress(alice);
        assertEq(meta.spendingPubKey, spending);
        assertEq(meta.viewingPubKey, viewing);
        assertTrue(meta.isRegistered);
    }
}
