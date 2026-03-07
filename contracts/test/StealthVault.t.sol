// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {StealthVault} from "../src/StealthVault.sol";
import {StealthPayment} from "../src/StealthPayment.sol";
import {IStealthVault} from "../src/interfaces/IStealthVault.sol";
import {IStealthPayment} from "../src/interfaces/IStealthPayment.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice Test token for vault tests
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title StealthVaultTest
/// @notice Comprehensive test suite for the StealthVault contract (Day 12-14)
/// @dev Tests commitment deposits, nullifier withdrawals, batch operations,
///      relayer withdrawals, emergency flows, and scanning helpers.
contract StealthVaultTest is Test {
    StealthVault public vault;
    StealthPayment public stealth;
    MockERC20 public token;

    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public relayer = makeAddr("relayer");
    address public attacker = makeAddr("attacker");

    // Test stealth addresses
    address public stealthAddr1 = makeAddr("stealth-1");
    address public stealthAddr2 = makeAddr("stealth-2");
    address public stealthAddr3 = makeAddr("stealth-3");

    // Test keys
    bytes32 public constant EPH_KEY_1 = keccak256("ephemeral-1");
    bytes32 public constant EPH_KEY_2 = keccak256("ephemeral-2");
    bytes32 public constant EPH_KEY_3 = keccak256("ephemeral-3");

    // Commitment parameters
    bytes32 public constant BLINDING_1 = keccak256("blinding-1");
    bytes32 public constant BLINDING_2 = keccak256("blinding-2");

    // Events from IStealthVault
    event CommitmentDeposited(
        uint256 indexed depositIndex, bytes32 indexed commitment,
        address token, uint256 amount, uint64 timestamp
    );
    event NullifierWithdrawal(
        bytes32 indexed nullifier, address indexed to,
        address token, uint256 amount, address relayer
    );
    event BatchStealthProcessed(
        address indexed sender, uint256 count, uint256 totalAmount, address token
    );
    event EmergencyWithdrawalInitiated(
        uint256 indexed depositIndex, address indexed depositor, uint256 unlockTime
    );
    event EmergencyWithdrawalExecuted(
        uint256 indexed depositIndex, address indexed depositor, address token, uint256 amount
    );
    event RelayerFeeCapUpdated(uint256 oldCap, uint256 newCap);
    event EmergencyTimelockUpdated(uint256 oldTimelock, uint256 newTimelock);

    // Events from IStealthPayment
    event Announcement(
        uint256 indexed schemeId, address indexed stealthAddress,
        address indexed caller, bytes32 ephemeralPubKey, bytes metadata
    );
    event StealthPaymentSent(
        address indexed stealthAddress, bytes32 indexed ephemeralPubKey,
        address token, uint256 amount, uint8 viewTag
    );

    function setUp() public {
        stealth = new StealthPayment();
        vault = new StealthVault(address(stealth));
        token = new MockERC20();

        // Authorize vault as delegated withdrawal caller on StealthPayment
        stealth.setAuthorizedVault(address(vault));

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(relayer, 10 ether);
        vm.deal(attacker, 10 ether);

        token.mint(alice, 1000 ether);
        token.mint(bob, 1000 ether);
    }

    // =========================================================================
    // Constructor Tests
    // =========================================================================

    function test_constructor_setsStealthPayment() public view {
        assertEq(address(vault.stealthPayment()), address(stealth));
    }

    function test_constructor_defaultRelayerFeeCap() public view {
        assertEq(vault.relayerFeeCap(), 200); // 2%
    }

    function test_constructor_defaultEmergencyTimelock() public view {
        assertEq(vault.emergencyTimelock(), 3 days);
    }

    function test_constructor_revertZeroStealthPayment() public {
        vm.expectRevert(IStealthVault.StealthPaymentNotSet.selector);
        new StealthVault(address(0));
    }

    // =========================================================================
    // Commitment Deposit Tests — Native Token
    // =========================================================================

    function test_depositNative_success() public {
        uint256 amount = 5 ether;
        bytes32 commitment = _computeCommitment(amount, BLINDING_1, alice);

        vm.prank(alice);
        vault.depositWithCommitment{value: amount}(commitment);

        assertEq(vault.getDepositCount(), 1);

        IStealthVault.CommitmentDeposit memory dep = vault.getDeposit(0);
        assertEq(dep.commitment, commitment);
        assertEq(dep.token, address(0));
        assertFalse(dep.withdrawn);
        assertEq(dep.timestamp, uint64(block.timestamp));
    }

    function test_depositNative_emitsEvent() public {
        uint256 amount = 3 ether;
        bytes32 commitment = _computeCommitment(amount, BLINDING_1, alice);

        vm.expectEmit(true, true, true, true);
        emit CommitmentDeposited(0, commitment, address(0), amount, uint64(block.timestamp));

        vm.prank(alice);
        vault.depositWithCommitment{value: amount}(commitment);
    }

    function test_depositNative_multipleDeposits() public {
        bytes32 c1 = _computeCommitment(1 ether, BLINDING_1, alice);
        bytes32 c2 = _computeCommitment(2 ether, BLINDING_2, alice);

        vm.startPrank(alice);
        vault.depositWithCommitment{value: 1 ether}(c1);
        vault.depositWithCommitment{value: 2 ether}(c2);
        vm.stopPrank();

        assertEq(vault.getDepositCount(), 2);
    }

    function test_depositNative_revertZeroCommitment() public {
        vm.prank(alice);
        vm.expectRevert(IStealthVault.InvalidCommitment.selector);
        vault.depositWithCommitment{value: 1 ether}(bytes32(0));
    }

    function test_depositNative_revertZeroAmount() public {
        bytes32 commitment = _computeCommitment(0, BLINDING_1, alice);
        vm.prank(alice);
        vm.expectRevert(IStealthVault.InvalidAmount.selector);
        vault.depositWithCommitment{value: 0}(commitment);
    }

    // =========================================================================
    // Commitment Deposit Tests — ERC20 Token
    // =========================================================================

    function test_depositToken_success() public {
        uint256 amount = 100 ether;
        bytes32 commitment = _computeCommitment(amount, BLINDING_1, alice);

        vm.startPrank(alice);
        token.approve(address(vault), amount);
        vault.depositTokenWithCommitment(address(token), amount, commitment);
        vm.stopPrank();

        assertEq(vault.getDepositCount(), 1);
        IStealthVault.CommitmentDeposit memory dep = vault.getDeposit(0);
        assertEq(dep.commitment, commitment);
        assertEq(dep.token, address(token));
        assertFalse(dep.withdrawn);
    }

    function test_depositToken_revertZeroToken() public {
        vm.prank(alice);
        vm.expectRevert(IStealthVault.InvalidAddress.selector);
        vault.depositTokenWithCommitment(address(0), 100 ether, BLINDING_1);
    }

    function test_depositToken_revertZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IStealthVault.InvalidAmount.selector);
        vault.depositTokenWithCommitment(address(token), 0, BLINDING_1);
    }

    // =========================================================================
    // Nullifier Withdrawal Tests
    // =========================================================================

    function test_withdrawNullifier_native_success() public {
        uint256 amount = 5 ether;
        bytes32 commitment = _computeCommitment(amount, BLINDING_1, alice);
        bytes32 nullifier = keccak256(abi.encodePacked("secret-1", uint256(0)));

        vm.prank(alice);
        vault.depositWithCommitment{value: amount}(commitment);

        address dest = makeAddr("dest");
        uint256 destBalBefore = dest.balance;

        vm.prank(bob); // Anyone can withdraw with correct nullifier/proof
        vault.withdrawWithNullifier(nullifier, 0, amount, BLINDING_1, dest);

        assertEq(dest.balance, destBalBefore + amount);
        assertTrue(vault.isNullifierUsed(nullifier));

        IStealthVault.CommitmentDeposit memory dep = vault.getDeposit(0);
        assertTrue(dep.withdrawn);
    }

    function test_withdrawNullifier_emitsEvent() public {
        uint256 amount = 3 ether;
        bytes32 commitment = _computeCommitment(amount, BLINDING_1, alice);
        bytes32 nullifier = keccak256(abi.encodePacked("secret-nul"));

        vm.prank(alice);
        vault.depositWithCommitment{value: amount}(commitment);

        address dest = makeAddr("dest");

        vm.expectEmit(true, true, true, true);
        emit NullifierWithdrawal(nullifier, dest, address(0), amount, address(0));

        vault.withdrawWithNullifier(nullifier, 0, amount, BLINDING_1, dest);
    }

    function test_withdrawNullifier_token_success() public {
        uint256 amount = 50 ether;
        bytes32 commitment = _computeCommitment(amount, BLINDING_2, alice);
        bytes32 nullifier = keccak256(abi.encodePacked("token-nullifier"));

        vm.startPrank(alice);
        token.approve(address(vault), amount);
        vault.depositTokenWithCommitment(address(token), amount, commitment);
        vm.stopPrank();

        address dest = makeAddr("dest-token");
        vault.withdrawWithNullifier(nullifier, 0, amount, BLINDING_2, dest);

        assertEq(token.balanceOf(dest), amount);
        assertTrue(vault.isNullifierUsed(nullifier));
    }

    function test_withdrawNullifier_revertNullifierAlreadyUsed() public {
        uint256 amount = 1 ether;
        bytes32 commitment = _computeCommitment(amount, BLINDING_1, alice);
        bytes32 nullifier = keccak256("nullifier-1");

        vm.prank(alice);
        vault.depositWithCommitment{value: amount}(commitment);

        vault.withdrawWithNullifier(nullifier, 0, amount, BLINDING_1, bob);

        // Second withdrawal with same nullifier
        vm.expectRevert(IStealthVault.NullifierAlreadyUsed.selector);
        vault.withdrawWithNullifier(nullifier, 0, amount, BLINDING_1, bob);
    }

    function test_withdrawNullifier_revertAlreadyWithdrawn() public {
        uint256 amount = 1 ether;
        bytes32 commitment = _computeCommitment(amount, BLINDING_1, alice);

        vm.prank(alice);
        vault.depositWithCommitment{value: amount}(commitment);

        bytes32 nul1 = keccak256("nul-a");
        vault.withdrawWithNullifier(nul1, 0, amount, BLINDING_1, bob);

        // Different nullifier but same deposit
        bytes32 nul2 = keccak256("nul-b");
        vm.expectRevert(IStealthVault.DepositAlreadyWithdrawn.selector);
        vault.withdrawWithNullifier(nul2, 0, amount, BLINDING_1, bob);
    }

    function test_withdrawNullifier_revertCommitmentMismatch() public {
        uint256 amount = 2 ether;
        bytes32 commitment = _computeCommitment(amount, BLINDING_1, alice);

        vm.prank(alice);
        vault.depositWithCommitment{value: amount}(commitment);

        bytes32 nullifier = keccak256("bad-nullifier");

        // Wrong amount
        vm.expectRevert(IStealthVault.CommitmentMismatch.selector);
        vault.withdrawWithNullifier(nullifier, 0, 3 ether, BLINDING_1, bob);
    }

    function test_withdrawNullifier_revertWrongBlinding() public {
        uint256 amount = 2 ether;
        bytes32 commitment = _computeCommitment(amount, BLINDING_1, alice);

        vm.prank(alice);
        vault.depositWithCommitment{value: amount}(commitment);

        bytes32 nullifier = keccak256("wrong-blinding");

        // Wrong blinding factor
        vm.expectRevert(IStealthVault.CommitmentMismatch.selector);
        vault.withdrawWithNullifier(nullifier, 0, amount, BLINDING_2, bob);
    }

    function test_withdrawNullifier_revertZeroNullifier() public {
        vm.expectRevert(IStealthVault.InvalidNullifier.selector);
        vault.withdrawWithNullifier(bytes32(0), 0, 1 ether, BLINDING_1, bob);
    }

    function test_withdrawNullifier_revertZeroDestination() public {
        vm.expectRevert(IStealthVault.InvalidAddress.selector);
        vault.withdrawWithNullifier(keccak256("x"), 0, 1 ether, BLINDING_1, address(0));
    }

    function test_withdrawNullifier_revertDepositNotFound() public {
        vm.expectRevert(IStealthVault.DepositNotFound.selector);
        vault.withdrawWithNullifier(keccak256("x"), 999, 1 ether, BLINDING_1, bob);
    }

    // =========================================================================
    // Batch Native Stealth Payment Tests
    // =========================================================================

    function test_batchNative_success() public {
        IStealthVault.BatchStealthPayment[] memory payments = new IStealthVault.BatchStealthPayment[](3);
        payments[0] = IStealthVault.BatchStealthPayment(stealthAddr1, 1 ether, EPH_KEY_1, 0xAB);
        payments[1] = IStealthVault.BatchStealthPayment(stealthAddr2, 2 ether, EPH_KEY_2, 0xCD);
        payments[2] = IStealthVault.BatchStealthPayment(stealthAddr3, 0.5 ether, EPH_KEY_3, 0xEF);

        vm.prank(alice);
        vault.batchSendNativeToStealth{value: 3.5 ether}(payments, "");

        // Check balances via StealthPayment
        assertEq(stealth.getStealthBalance(stealthAddr1, address(0)), 1 ether);
        assertEq(stealth.getStealthBalance(stealthAddr2, address(0)), 2 ether);
        assertEq(stealth.getStealthBalance(stealthAddr3, address(0)), 0.5 ether);
    }

    function test_batchNative_emitsBatchEvent() public {
        IStealthVault.BatchStealthPayment[] memory payments = new IStealthVault.BatchStealthPayment[](2);
        payments[0] = IStealthVault.BatchStealthPayment(stealthAddr1, 1 ether, EPH_KEY_1, 0xAB);
        payments[1] = IStealthVault.BatchStealthPayment(stealthAddr2, 2 ether, EPH_KEY_2, 0xCD);

        vm.expectEmit(true, true, true, true);
        emit BatchStealthProcessed(alice, 2, 3 ether, address(0));

        vm.prank(alice);
        vault.batchSendNativeToStealth{value: 3 ether}(payments, "");
    }

    function test_batchNative_revertEmptyBatch() public {
        IStealthVault.BatchStealthPayment[] memory payments = new IStealthVault.BatchStealthPayment[](0);

        vm.prank(alice);
        vm.expectRevert(IStealthVault.BatchTooLarge.selector);
        vault.batchSendNativeToStealth{value: 0}(payments, "");
    }

    function test_batchNative_revertAmountMismatch() public {
        IStealthVault.BatchStealthPayment[] memory payments = new IStealthVault.BatchStealthPayment[](1);
        payments[0] = IStealthVault.BatchStealthPayment(stealthAddr1, 1 ether, EPH_KEY_1, 0xAB);

        vm.prank(alice);
        vm.expectRevert(IStealthVault.BatchAmountMismatch.selector);
        vault.batchSendNativeToStealth{value: 2 ether}(payments, "");
    }

    function test_batchNative_revertZeroStealthAddress() public {
        IStealthVault.BatchStealthPayment[] memory payments = new IStealthVault.BatchStealthPayment[](1);
        payments[0] = IStealthVault.BatchStealthPayment(address(0), 1 ether, EPH_KEY_1, 0xAB);

        vm.prank(alice);
        vm.expectRevert(IStealthVault.InvalidAddress.selector);
        vault.batchSendNativeToStealth{value: 1 ether}(payments, "");
    }

    function test_batchNative_revertZeroAmount() public {
        IStealthVault.BatchStealthPayment[] memory payments = new IStealthVault.BatchStealthPayment[](1);
        payments[0] = IStealthVault.BatchStealthPayment(stealthAddr1, 0, EPH_KEY_1, 0xAB);

        vm.prank(alice);
        vm.expectRevert(IStealthVault.InvalidAmount.selector);
        vault.batchSendNativeToStealth{value: 0}(payments, "");
    }

    // =========================================================================
    // Batch Token Stealth Payment Tests
    // =========================================================================

    function test_batchToken_success() public {
        IStealthVault.BatchStealthPayment[] memory payments = new IStealthVault.BatchStealthPayment[](2);
        payments[0] = IStealthVault.BatchStealthPayment(stealthAddr1, 50 ether, EPH_KEY_1, 0xAB);
        payments[1] = IStealthVault.BatchStealthPayment(stealthAddr2, 30 ether, EPH_KEY_2, 0xCD);

        vm.startPrank(alice);
        token.approve(address(vault), 80 ether);
        vault.batchSendTokenToStealth(address(token), payments, "");
        vm.stopPrank();

        assertEq(stealth.getStealthBalance(stealthAddr1, address(token)), 50 ether);
        assertEq(stealth.getStealthBalance(stealthAddr2, address(token)), 30 ether);
    }

    function test_batchToken_revertZeroToken() public {
        IStealthVault.BatchStealthPayment[] memory payments = new IStealthVault.BatchStealthPayment[](1);
        payments[0] = IStealthVault.BatchStealthPayment(stealthAddr1, 10 ether, EPH_KEY_1, 0xAB);

        vm.prank(alice);
        vm.expectRevert(IStealthVault.InvalidAddress.selector);
        vault.batchSendTokenToStealth(address(0), payments, "");
    }

    // =========================================================================
    // Relayer Withdrawal Tests (StealthVault) — Real Fund Transfers
    // =========================================================================

    event RelayerWithdrawalProcessed(
        address indexed stealthAddress, address indexed to, address indexed relayer,
        address token, uint256 amount, uint256 relayerFee
    );

    function test_vaultRelayer_nativeWithdraw_success() public {
        // 1. Create a stealth address we can sign from
        uint256 stealthPrivKey = uint256(keccak256("vault-stealth-key-1"));
        address stealthSigner = vm.addr(stealthPrivKey);

        // 2. Send funds to stealth address via StealthPayment
        vm.prank(alice);
        stealth.sendNativeToStealth{value: 10 ether}(stealthSigner, EPH_KEY_1, 0xAB, "");
        assertEq(stealth.getStealthBalance(stealthSigner, address(0)), 10 ether);

        // 3. Build the withdrawal hash matching vault's DOMAIN_SEPARATOR_SALT
        uint256 relayerFeeAmount = 0.1 ether; // 1% of 10 ether
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 withdrawalHash = keccak256(abi.encodePacked(
            vault.DOMAIN_SEPARATOR_SALT(),
            stealthSigner,
            address(0),
            bob,
            relayerFeeAmount,
            deadline,
            block.chainid
        ));

        // 4. Sign with stealth address private key (EIP-191)
        bytes32 ethSignedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32", withdrawalHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(stealthPrivKey, ethSignedHash);

        // 5. Record balances before
        uint256 bobBefore = bob.balance;
        uint256 relayerBefore = relayer.balance;

        // 6. Relayer submits withdrawal through vault
        IStealthVault.RelayerWithdrawal memory withdrawal = IStealthVault.RelayerWithdrawal({
            stealthAddress: stealthSigner,
            token: address(0),
            to: bob,
            relayerFee: relayerFeeAmount,
            deadline: deadline
        });

        vm.prank(relayer);
        vault.withdrawViaRelayer(withdrawal, v, r, s);

        // 7. Verify actual fund transfers happened
        assertEq(bob.balance, bobBefore + 10 ether - relayerFeeAmount, "Bob should receive funds minus fee");
        assertEq(relayer.balance, relayerBefore + relayerFeeAmount, "Relayer should receive fee");
        assertEq(stealth.getStealthBalance(stealthSigner, address(0)), 0, "Stealth balance should be zero");
    }

    function test_vaultRelayer_tokenWithdraw_success() public {
        uint256 stealthPrivKey = uint256(keccak256("vault-stealth-token-key"));
        address stealthSigner = vm.addr(stealthPrivKey);

        // Send tokens to stealth address
        uint256 amount = 500 ether;
        vm.startPrank(alice);
        token.approve(address(stealth), amount);
        stealth.sendTokenToStealth(address(token), amount, stealthSigner, EPH_KEY_2, 0xCD, "");
        vm.stopPrank();

        assertEq(stealth.getStealthBalance(stealthSigner, address(token)), amount);

        // Build and sign
        uint256 fee = 5 ether; // 1% of 500
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 withdrawalHash = keccak256(abi.encodePacked(
            vault.DOMAIN_SEPARATOR_SALT(), stealthSigner, address(token),
            bob, fee, deadline, block.chainid
        ));
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", withdrawalHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(stealthPrivKey, ethSigned);

        uint256 bobTokenBefore = token.balanceOf(bob);
        uint256 relayerTokenBefore = token.balanceOf(relayer);

        IStealthVault.RelayerWithdrawal memory wd = IStealthVault.RelayerWithdrawal({
            stealthAddress: stealthSigner, token: address(token),
            to: bob, relayerFee: fee, deadline: deadline
        });

        vm.prank(relayer);
        vault.withdrawViaRelayer(wd, v, r, s);

        assertEq(token.balanceOf(bob), bobTokenBefore + amount - fee);
        assertEq(token.balanceOf(relayer), relayerTokenBefore + fee);
        assertEq(stealth.getStealthBalance(stealthSigner, address(token)), 0);
    }

    function test_vaultRelayer_emitsEvent() public {
        uint256 stealthPrivKey = uint256(keccak256("vault-stealth-event-key"));
        address stealthSigner = vm.addr(stealthPrivKey);

        vm.prank(alice);
        stealth.sendNativeToStealth{value: 5 ether}(stealthSigner, EPH_KEY_1, 0xAB, "");

        uint256 fee = 0.05 ether;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 wdHash = keccak256(abi.encodePacked(
            vault.DOMAIN_SEPARATOR_SALT(), stealthSigner, address(0),
            bob, fee, deadline, block.chainid
        ));
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", wdHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(stealthPrivKey, ethSigned);

        IStealthVault.RelayerWithdrawal memory wd = IStealthVault.RelayerWithdrawal({
            stealthAddress: stealthSigner, token: address(0),
            to: bob, relayerFee: fee, deadline: deadline
        });

        vm.expectEmit(true, true, true, true);
        emit RelayerWithdrawalProcessed(stealthSigner, bob, relayer, address(0), 5 ether - fee, fee);

        vm.prank(relayer);
        vault.withdrawViaRelayer(wd, v, r, s);
    }

    function test_vaultRelayer_revertExpired() public {
        uint256 stealthPrivKey = uint256(keccak256("vault-stealth-expired-key"));
        address stealthSigner = vm.addr(stealthPrivKey);

        vm.prank(alice);
        stealth.sendNativeToStealth{value: 5 ether}(stealthSigner, EPH_KEY_1, 0xAB, "");

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 wdHash = keccak256(abi.encodePacked(
            vault.DOMAIN_SEPARATOR_SALT(), stealthSigner, address(0),
            bob, uint256(0), deadline, block.chainid
        ));
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", wdHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(stealthPrivKey, ethSigned);

        // Warp past deadline
        vm.warp(deadline + 1);

        IStealthVault.RelayerWithdrawal memory wd = IStealthVault.RelayerWithdrawal({
            stealthAddress: stealthSigner, token: address(0),
            to: bob, relayerFee: 0, deadline: deadline
        });

        vm.prank(relayer);
        vm.expectRevert(IStealthVault.WithdrawalExpired.selector);
        vault.withdrawViaRelayer(wd, v, r, s);
    }

    function test_vaultRelayer_revertInvalidSignature() public {
        uint256 stealthPrivKey = uint256(keccak256("vault-stealth-bad-sig-key"));
        address stealthSigner = vm.addr(stealthPrivKey);
        uint256 wrongPrivKey = uint256(keccak256("wrong-key"));

        vm.prank(alice);
        stealth.sendNativeToStealth{value: 5 ether}(stealthSigner, EPH_KEY_1, 0xAB, "");

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 wdHash = keccak256(abi.encodePacked(
            vault.DOMAIN_SEPARATOR_SALT(), stealthSigner, address(0),
            bob, uint256(0), deadline, block.chainid
        ));
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", wdHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivKey, ethSigned); // wrong key!

        IStealthVault.RelayerWithdrawal memory wd = IStealthVault.RelayerWithdrawal({
            stealthAddress: stealthSigner, token: address(0),
            to: bob, relayerFee: 0, deadline: deadline
        });

        vm.prank(relayer);
        vm.expectRevert(IStealthVault.InvalidSignature.selector);
        vault.withdrawViaRelayer(wd, v, r, s);
    }

    function test_vaultRelayer_revertFeeTooHigh() public {
        uint256 stealthPrivKey = uint256(keccak256("vault-stealth-fee-key"));
        address stealthSigner = vm.addr(stealthPrivKey);

        vm.prank(alice);
        stealth.sendNativeToStealth{value: 10 ether}(stealthSigner, EPH_KEY_1, 0xAB, "");

        // 2% cap => max fee = 0.2 ether. Try 1 ether.
        uint256 deadline = block.timestamp + 1 hours;
        IStealthVault.RelayerWithdrawal memory wd = IStealthVault.RelayerWithdrawal({
            stealthAddress: stealthSigner, token: address(0),
            to: bob, relayerFee: 1 ether, deadline: deadline
        });

        bytes32 wdHash = keccak256(abi.encodePacked(
            vault.DOMAIN_SEPARATOR_SALT(), stealthSigner, address(0),
            bob, uint256(1 ether), deadline, block.chainid
        ));
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", wdHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(stealthPrivKey, ethSigned);

        vm.prank(relayer);
        vm.expectRevert(IStealthVault.RelayerFeeTooHigh.selector);
        vault.withdrawViaRelayer(wd, v, r, s);
    }

    function test_vaultRelayer_revertReplay() public {
        uint256 stealthPrivKey = uint256(keccak256("vault-stealth-replay-key"));
        address stealthSigner = vm.addr(stealthPrivKey);

        // Send 10 ether in two batches
        vm.prank(alice);
        stealth.sendNativeToStealth{value: 5 ether}(stealthSigner, EPH_KEY_1, 0xAB, "");

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 wdHash = keccak256(abi.encodePacked(
            vault.DOMAIN_SEPARATOR_SALT(), stealthSigner, address(0),
            bob, uint256(0), deadline, block.chainid
        ));
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", wdHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(stealthPrivKey, ethSigned);

        IStealthVault.RelayerWithdrawal memory wd = IStealthVault.RelayerWithdrawal({
            stealthAddress: stealthSigner, token: address(0),
            to: bob, relayerFee: 0, deadline: deadline
        });

        // First withdrawal succeeds
        vm.prank(relayer);
        vault.withdrawViaRelayer(wd, v, r, s);

        // Send more funds and try to replay
        vm.prank(alice);
        stealth.sendNativeToStealth{value: 5 ether}(stealthSigner, EPH_KEY_2, 0xCD, "");

        vm.prank(relayer);
        vm.expectRevert(IStealthVault.NullifierAlreadyUsed.selector);
        vault.withdrawViaRelayer(wd, v, r, s);
    }

    function test_vaultRelayer_zeroFee_success() public {
        uint256 stealthPrivKey = uint256(keccak256("vault-stealth-zerofee-key"));
        address stealthSigner = vm.addr(stealthPrivKey);

        vm.prank(alice);
        stealth.sendNativeToStealth{value: 3 ether}(stealthSigner, EPH_KEY_1, 0xAB, "");

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 wdHash = keccak256(abi.encodePacked(
            vault.DOMAIN_SEPARATOR_SALT(), stealthSigner, address(0),
            bob, uint256(0), deadline, block.chainid
        ));
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", wdHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(stealthPrivKey, ethSigned);

        uint256 bobBefore = bob.balance;

        IStealthVault.RelayerWithdrawal memory wd = IStealthVault.RelayerWithdrawal({
            stealthAddress: stealthSigner, token: address(0),
            to: bob, relayerFee: 0, deadline: deadline
        });

        vm.prank(relayer);
        vault.withdrawViaRelayer(wd, v, r, s);

        assertEq(bob.balance, bobBefore + 3 ether, "Bob gets full amount with zero fee");
    }

    // =========================================================================
    // Emergency Withdrawal Tests
    // =========================================================================

    function test_emergency_initiate_success() public {
        uint256 amount = 5 ether;
        bytes32 commitment = _computeCommitment(amount, BLINDING_1, alice);

        vm.prank(alice);
        vault.depositWithCommitment{value: amount}(commitment);

        uint256 expectedUnlock = block.timestamp + vault.emergencyTimelock();

        vm.expectEmit(true, true, true, true);
        emit EmergencyWithdrawalInitiated(0, alice, expectedUnlock);

        vm.prank(alice);
        vault.initiateEmergencyWithdrawal(0);

        assertEq(vault.getEmergencyUnlockTime(0), expectedUnlock);
    }

    function test_emergency_execute_success() public {
        uint256 amount = 5 ether;
        bytes32 commitment = _computeCommitment(amount, BLINDING_1, alice);

        vm.prank(alice);
        vault.depositWithCommitment{value: amount}(commitment);

        vm.prank(alice);
        vault.initiateEmergencyWithdrawal(0);

        // Warp past timelock
        vm.warp(block.timestamp + vault.emergencyTimelock() + 1);

        uint256 aliceBalBefore = alice.balance;

        vm.expectEmit(true, true, true, true);
        emit EmergencyWithdrawalExecuted(0, alice, address(0), amount);

        vm.prank(alice);
        vault.executeEmergencyWithdrawal(0, amount, BLINDING_1);

        assertEq(alice.balance, aliceBalBefore + amount);

        IStealthVault.CommitmentDeposit memory dep = vault.getDeposit(0);
        assertTrue(dep.withdrawn);
    }

    function test_emergency_revertNotDepositor() public {
        bytes32 commitment = _computeCommitment(1 ether, BLINDING_1, alice);

        vm.prank(alice);
        vault.depositWithCommitment{value: 1 ether}(commitment);

        vm.prank(attacker);
        vm.expectRevert(IStealthVault.NotDepositor.selector);
        vault.initiateEmergencyWithdrawal(0);
    }

    function test_emergency_revertTimelockNotElapsed() public {
        bytes32 commitment = _computeCommitment(1 ether, BLINDING_1, alice);

        vm.prank(alice);
        vault.depositWithCommitment{value: 1 ether}(commitment);

        vm.prank(alice);
        vault.initiateEmergencyWithdrawal(0);

        // Don't warp — timelock hasn't elapsed
        vm.prank(alice);
        vm.expectRevert(IStealthVault.EmergencyTimelockNotElapsed.selector);
        vault.executeEmergencyWithdrawal(0, 1 ether, BLINDING_1);
    }

    function test_emergency_revertNotInitiated() public {
        bytes32 commitment = _computeCommitment(1 ether, BLINDING_1, alice);

        vm.prank(alice);
        vault.depositWithCommitment{value: 1 ether}(commitment);

        vm.prank(alice);
        vm.expectRevert(IStealthVault.EmergencyNotInitiated.selector);
        vault.executeEmergencyWithdrawal(0, 1 ether, BLINDING_1);
    }

    function test_emergency_revertAlreadyWithdrawn() public {
        uint256 amount = 1 ether;
        bytes32 commitment = _computeCommitment(amount, BLINDING_1, alice);

        vm.prank(alice);
        vault.depositWithCommitment{value: amount}(commitment);

        // Normal withdrawal first
        bytes32 nullifier = keccak256("nul-cancel");
        vault.withdrawWithNullifier(nullifier, 0, amount, BLINDING_1, bob);

        vm.prank(alice);
        vm.expectRevert(IStealthVault.DepositAlreadyWithdrawn.selector);
        vault.initiateEmergencyWithdrawal(0);
    }

    function test_emergency_token_success() public {
        uint256 amount = 100 ether;
        bytes32 commitment = _computeCommitment(amount, BLINDING_2, alice);

        vm.startPrank(alice);
        token.approve(address(vault), amount);
        vault.depositTokenWithCommitment(address(token), amount, commitment);
        vault.initiateEmergencyWithdrawal(0);
        vm.stopPrank();

        vm.warp(block.timestamp + vault.emergencyTimelock() + 1);

        uint256 aliceTokenBefore = token.balanceOf(alice);

        vm.prank(alice);
        vault.executeEmergencyWithdrawal(0, amount, BLINDING_2);

        assertEq(token.balanceOf(alice), aliceTokenBefore + amount);
    }

    // =========================================================================
    // Scanning Helper Tests
    // =========================================================================

    function test_computeViewTag() public view {
        bytes32 secret = keccak256("shared-secret-1");
        uint8 tag = vault.computeViewTag(secret);

        // Verify it matches manual computation
        uint8 expected = uint8(uint256(keccak256(abi.encodePacked(secret))) >> 248);
        assertEq(tag, expected);
    }

    function test_computeStealthAddress_matchesCryptoRegistry() public view {
        bytes32 spendingKey = keccak256("spending-key");
        bytes32 sharedSecretHash = keccak256("shared-secret-hash");

        address derived = vault.computeStealthAddress(spendingKey, sharedSecretHash);

        // Matches the domain-separator derivation
        address expected = address(uint160(uint256(keccak256(abi.encodePacked(
            "OmniShield::Stealth::v1",
            spendingKey,
            sharedSecretHash
        )))));
        assertEq(derived, expected);
    }

    function test_computeStealthAddress_deterministicAndUnique() public view {
        bytes32 spendKey = keccak256("spend");
        bytes32 secret1 = keccak256("secret-1");
        bytes32 secret2 = keccak256("secret-2");

        address addr1 = vault.computeStealthAddress(spendKey, secret1);
        address addr2 = vault.computeStealthAddress(spendKey, secret2);

        // Same inputs produce same output
        assertEq(addr1, vault.computeStealthAddress(spendKey, secret1));
        // Different inputs produce different output
        assertNotEq(addr1, addr2);
    }

    function test_computeViewTag_differentSecrets() public view {
        bytes32 secret1 = keccak256("a");
        bytes32 secret2 = keccak256("b");

        uint8 tag1 = vault.computeViewTag(secret1);
        uint8 tag2 = vault.computeViewTag(secret2);

        // Tags exist (don't assert inequality — collision possible for 1 byte)
        assertTrue(tag1 <= 255 && tag2 <= 255);
    }

    // =========================================================================
    // Admin Tests
    // =========================================================================

    function test_setRelayerFeeCap() public {
        vm.expectEmit(true, true, true, true);
        emit RelayerFeeCapUpdated(200, 300);

        vault.setRelayerFeeCap(300);
        assertEq(vault.relayerFeeCap(), 300);
    }

    function test_setRelayerFeeCap_revertTooHigh() public {
        vm.expectRevert("Fee cap too high");
        vault.setRelayerFeeCap(600); // > 500
    }

    function test_setRelayerFeeCap_revertNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setRelayerFeeCap(100);
    }

    function test_setEmergencyTimelock() public {
        vm.expectEmit(true, true, true, true);
        emit EmergencyTimelockUpdated(3 days, 7 days);

        vault.setEmergencyTimelock(7 days);
        assertEq(vault.emergencyTimelock(), 7 days);
    }

    function test_setEmergencyTimelock_revertTooShort() public {
        vm.expectRevert("Timelock too short");
        vault.setEmergencyTimelock(12 hours); // < 1 day
    }

    function test_setStealthPayment() public {
        StealthPayment newStealth = new StealthPayment();
        vault.setStealthPayment(address(newStealth));
        assertEq(address(vault.stealthPayment()), address(newStealth));
    }

    function test_setStealthPayment_revertZero() public {
        vm.expectRevert(IStealthVault.StealthPaymentNotSet.selector);
        vault.setStealthPayment(address(0));
    }

    function test_pause_unpause() public {
        vault.pause();
        assertTrue(vault.paused());

        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_pause_revertNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.pause();
    }

    function test_depositRevertWhenPaused() public {
        vault.pause();
        vm.prank(alice);
        vm.expectRevert();
        vault.depositWithCommitment{value: 1 ether}(keccak256("x"));
    }

    // =========================================================================
    // Receive Test
    // =========================================================================

    function test_receive_revertDirectTransfer() public {
        vm.prank(alice);
        vm.expectRevert("Use depositWithCommitment");
        (bool success,) = address(vault).call{value: 1 ether}("");
        success; // silence unused warning
    }

    // =========================================================================
    // View Function Tests
    // =========================================================================

    function test_getDeposit_revertNotFound() public {
        vm.expectRevert(IStealthVault.DepositNotFound.selector);
        vault.getDeposit(0);
    }

    function test_getDepositor() public {
        bytes32 commitment = _computeCommitment(1 ether, BLINDING_1, alice);
        vm.prank(alice);
        vault.depositWithCommitment{value: 1 ether}(commitment);
        assertEq(vault.getDepositor(0), alice);
    }

    function test_isNullifierUsed_default() public view {
        assertFalse(vault.isNullifierUsed(keccak256("unused")));
    }

    // =========================================================================
    // Fuzz Tests
    // =========================================================================

    function testFuzz_depositAndWithdraw_noValueLeak(uint256 amount) public {
        amount = bound(amount, 1 wei, 1_000_000 ether);
        vm.deal(alice, amount);

        bytes32 blinding = keccak256(abi.encode(amount, "fuzz-blinding"));
        bytes32 commitment = _computeCommitment(amount, blinding, alice);

        vm.prank(alice);
        vault.depositWithCommitment{value: amount}(commitment);

        assertEq(vault.getDepositCount(), 1);

        address dest = makeAddr("fuzz-dest");
        uint256 destBefore = dest.balance;
        bytes32 nullifier = keccak256(abi.encode(amount, "fuzz-nullifier"));

        vault.withdrawWithNullifier(nullifier, 0, amount, blinding, dest);
        assertEq(dest.balance, destBefore + amount);
    }

    function testFuzz_viewTag_always8bit(bytes32 secret) public view {
        uint8 tag = vault.computeViewTag(secret);
        assertTrue(tag <= 255);
    }

    function testFuzz_stealthAddress_deterministicDerivation(
        bytes32 spendKey,
        bytes32 secretHash
    ) public view {
        address a1 = vault.computeStealthAddress(spendKey, secretHash);
        address a2 = vault.computeStealthAddress(spendKey, secretHash);
        assertEq(a1, a2);
    }

    function testFuzz_commitment_uniquePerParams(uint256 amount, bytes32 blinding) public view {
        amount = bound(amount, 1, type(uint128).max);
        bytes32 c1 = _computeCommitment(amount, blinding, alice);
        bytes32 c2 = _computeCommitment(amount, blinding, bob);
        // Different depositor = different commitment
        assertNotEq(c1, c2);
    }

    // =========================================================================
    // Integration Tests — Full Privacy Flow
    // =========================================================================

    function test_fullPrivacyFlow_depositCommitAndWithdraw() public {
        // === COMPLETE PRIVATE PAYMENT FLOW ===
        //
        // Step 1: Alice generates stealth meta-address (off-chain: spending + viewing keys)
        bytes32 spendingKey = keccak256("alice-spending-key");
        bytes32 viewingKey = keccak256("alice-viewing-key");

        // Step 2: Alice registers stealth meta-address on-chain
        vm.prank(alice);
        stealth.registerStealthMetaAddress(spendingKey, viewingKey);

        // Step 3: Bob wants to pay Alice privately
        // Bob computes ECDH shared secret (off-chain) with Alice's viewing key
        bytes32 sharedSecret = keccak256(abi.encodePacked("ecdh-shared-secret", viewingKey));
        bytes32 sharedSecretHash = keccak256(abi.encodePacked(sharedSecret));

        // Step 4: Bob computes the stealth address and view tag
        address stealthAddress = vault.computeStealthAddress(spendingKey, sharedSecretHash);
        uint8 viewTag = vault.computeViewTag(sharedSecret);

        // Step 5: Bob sends payment to the stealth address
        bytes32 ephemeralKey = keccak256("bob-ephemeral-key");
        vm.prank(bob);
        stealth.sendNativeToStealth{value: 10 ether}(stealthAddress, ephemeralKey, viewTag, "");

        // Step 6: Verify funds arrived at stealth address
        assertEq(stealth.getStealthBalance(stealthAddress, address(0)), 10 ether);

        // Step 7: Alice scans announcements (off-chain) and finds payment using view tag
        // She computes the same shared secret using her viewing key + Bob's ephemeral key
        // She derives the stealth private key and withdraws

        // Step 8: Alice (as stealth address) withdraws to her real address
        address aliceFinal = makeAddr("alice-final-destination");
        uint256 finalBalBefore = aliceFinal.balance;

        vm.prank(stealthAddress);
        stealth.withdrawFromStealth(address(0), aliceFinal);

        assertEq(aliceFinal.balance, finalBalBefore + 10 ether);
        assertEq(stealth.getStealthBalance(stealthAddress, address(0)), 0);
    }

    function test_fullPrivacyFlow_commitmentVault() public {
        // === COMMITMENT-BASED PRIVACY FLOW ===
        //
        // Step 1: Alice deposits with a commitment (amount hidden on-chain conceptually)
        uint256 amount = 7 ether;
        bytes32 blinding = keccak256("alice-blinding-factor");
        bytes32 commitment = _computeCommitment(amount, blinding, alice);

        vm.prank(alice);
        vault.depositWithCommitment{value: amount}(commitment);

        // Step 2: Later, Alice (or anyone with the secret) withdraws with nullifier
        // The nullifier prevents double-spend without linking to the deposit
        bytes32 nullifier = keccak256(abi.encodePacked("alice-withdraw-secret", uint256(0)));
        address dest = makeAddr("alice-private-dest");

        vault.withdrawWithNullifier(nullifier, 0, amount, blinding, dest);
        assertEq(dest.balance, amount);

        // Step 3: The nullifier is consumed — can't withdraw again
        bytes32 nullifier2 = keccak256("try-again");
        vm.expectRevert(IStealthVault.DepositAlreadyWithdrawn.selector);
        vault.withdrawWithNullifier(nullifier2, 0, amount, blinding, dest);
    }

    function test_fullPrivacyFlow_batchAndWithdraw() public {
        // === BATCH STEALTH PAYMENT FLOW ===
        // Bob pays 3 recipients in one transaction (more privacy - unclear who gets what)

        bytes32 spendKey1 = keccak256("r1-spend");
        bytes32 spendKey2 = keccak256("r2-spend");
        bytes32 spendKey3 = keccak256("r3-spend");

        bytes32 secret1 = keccak256("secret-r1");
        bytes32 secret2 = keccak256("secret-r2");
        bytes32 secret3 = keccak256("secret-r3");

        address sa1 = vault.computeStealthAddress(spendKey1, secret1);
        address sa2 = vault.computeStealthAddress(spendKey2, secret2);
        address sa3 = vault.computeStealthAddress(spendKey3, secret3);

        IStealthVault.BatchStealthPayment[] memory payments = new IStealthVault.BatchStealthPayment[](3);
        payments[0] = IStealthVault.BatchStealthPayment(sa1, 1 ether, EPH_KEY_1, 0xAA);
        payments[1] = IStealthVault.BatchStealthPayment(sa2, 2 ether, EPH_KEY_2, 0xBB);
        payments[2] = IStealthVault.BatchStealthPayment(sa3, 3 ether, EPH_KEY_3, 0xCC);

        vm.prank(bob);
        vault.batchSendNativeToStealth{value: 6 ether}(payments, "");

        // All three recipients have funds
        assertEq(stealth.getStealthBalance(sa1, address(0)), 1 ether);
        assertEq(stealth.getStealthBalance(sa2, address(0)), 2 ether);
        assertEq(stealth.getStealthBalance(sa3, address(0)), 3 ether);

        // Each recipient withdraws independently
        address dest1 = makeAddr("dest-r1");
        address dest2 = makeAddr("dest-r2");
        address dest3 = makeAddr("dest-r3");

        vm.prank(sa1);
        stealth.withdrawFromStealth(address(0), dest1);
        assertEq(dest1.balance, 1 ether);

        vm.prank(sa2);
        stealth.withdrawFromStealth(address(0), dest2);
        assertEq(dest2.balance, 2 ether);

        vm.prank(sa3);
        stealth.withdrawFromStealth(address(0), dest3);
        assertEq(dest3.balance, 3 ether);
    }

    // =========================================================================
    // StealthPayment Enhancement Tests — Batch & Relayer
    // =========================================================================

    function test_sp_batchNative_success() public {
        StealthPayment.BatchEntry[] memory entries = new StealthPayment.BatchEntry[](2);
        entries[0] = StealthPayment.BatchEntry(stealthAddr1, EPH_KEY_1, 0xAB, 1 ether);
        entries[1] = StealthPayment.BatchEntry(stealthAddr2, EPH_KEY_2, 0xCD, 2 ether);

        vm.prank(alice);
        stealth.batchSendNativeToStealth{value: 3 ether}(entries, "");

        assertEq(stealth.getStealthBalance(stealthAddr1, address(0)), 1 ether);
        assertEq(stealth.getStealthBalance(stealthAddr2, address(0)), 2 ether);
        assertEq(stealth.getAnnouncementCount(), 2);
    }

    function test_sp_batchNative_revertValueMismatch() public {
        StealthPayment.BatchEntry[] memory entries = new StealthPayment.BatchEntry[](1);
        entries[0] = StealthPayment.BatchEntry(stealthAddr1, EPH_KEY_1, 0xAB, 1 ether);

        vm.prank(alice);
        vm.expectRevert("Value mismatch");
        stealth.batchSendNativeToStealth{value: 5 ether}(entries, "");
    }

    function test_sp_batchNative_revertEmptyBatch() public {
        StealthPayment.BatchEntry[] memory entries = new StealthPayment.BatchEntry[](0);

        vm.prank(alice);
        vm.expectRevert("Invalid batch size");
        stealth.batchSendNativeToStealth{value: 0}(entries, "");
    }

    function test_sp_batchToken_success() public {
        StealthPayment.BatchEntry[] memory entries = new StealthPayment.BatchEntry[](2);
        entries[0] = StealthPayment.BatchEntry(stealthAddr1, EPH_KEY_1, 0xAB, 50 ether);
        entries[1] = StealthPayment.BatchEntry(stealthAddr2, EPH_KEY_2, 0xCD, 30 ether);

        vm.startPrank(alice);
        token.approve(address(stealth), 80 ether);
        stealth.batchSendTokenToStealth(address(token), entries, "");
        vm.stopPrank();

        assertEq(stealth.getStealthBalance(stealthAddr1, address(token)), 50 ether);
        assertEq(stealth.getStealthBalance(stealthAddr2, address(token)), 30 ether);
    }

    function test_sp_batchToken_revertInvalidToken() public {
        StealthPayment.BatchEntry[] memory entries = new StealthPayment.BatchEntry[](1);
        entries[0] = StealthPayment.BatchEntry(stealthAddr1, EPH_KEY_1, 0xAB, 50 ether);

        vm.prank(alice);
        vm.expectRevert("Invalid token");
        stealth.batchSendTokenToStealth(address(0), entries, "");
    }

    function test_sp_batchNative_revertWhenPaused() public {
        stealth.pause();

        StealthPayment.BatchEntry[] memory entries = new StealthPayment.BatchEntry[](1);
        entries[0] = StealthPayment.BatchEntry(stealthAddr1, EPH_KEY_1, 0xAB, 1 ether);

        vm.prank(alice);
        vm.expectRevert();
        stealth.batchSendNativeToStealth{value: 1 ether}(entries, "");
    }

    function test_sp_computeViewTag() public view {
        bytes32 secret = keccak256("test-shared-secret");
        uint8 tag = stealth.computeViewTag(secret);
        uint8 expected = uint8(uint256(keccak256(abi.encodePacked(secret))) >> 248);
        assertEq(tag, expected);
    }

    function test_sp_computeStealthAddress() public view {
        bytes32 spendKey = keccak256("spend-key");
        bytes32 secretHash = keccak256("secret-hash");

        address derived = stealth.computeStealthAddress(spendKey, secretHash);
        address expected = address(uint160(uint256(keccak256(abi.encodePacked(
            "OmniShield::Stealth::v1", spendKey, secretHash
        )))));
        assertEq(derived, expected);
    }

    // =========================================================================
    // StealthPayment Relayer Withdrawal Tests
    // =========================================================================

    function test_sp_relayerWithdraw_success() public {
        // Setup: Send funds to stealth address
        vm.prank(alice);
        stealth.sendNativeToStealth{value: 10 ether}(stealthAddr1, EPH_KEY_1, 0xAB, "");

        // Stealth address owner signs withdrawal authorization
        uint256 stealthPrivateKey = uint256(keccak256(abi.encodePacked("stealth-key-1")));
        address stealthSigner = vm.addr(stealthPrivateKey);

        // Send funds to the signer address stealth balance mapping directly
        // First, create a stealth address we can control
        vm.prank(alice);
        stealth.sendNativeToStealth{value: 5 ether}(stealthSigner, EPH_KEY_2, 0xCD, "");

        // Build the withdrawal hash
        uint256 relayerFeeAmount = 0.05 ether; // 1% of 5 ether
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 withdrawalHash = keccak256(abi.encodePacked(
            stealth.WITHDRAWAL_DOMAIN(),
            stealthSigner,
            address(0), // native token
            bob,        // destination
            relayerFeeAmount,
            deadline,
            block.chainid
        ));

        bytes32 ethSignedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            withdrawalHash
        ));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(stealthPrivateKey, ethSignedHash);

        uint256 bobBalBefore = bob.balance;
        uint256 relayerBalBefore = relayer.balance;

        vm.prank(relayer);
        stealth.withdrawViaRelayer(
            stealthSigner,
            address(0),
            bob,
            relayerFeeAmount,
            deadline,
            v, r, s
        );

        // Bob gets 5 ether - fee
        assertEq(bob.balance, bobBalBefore + 5 ether - relayerFeeAmount);
        // Relayer gets fee
        assertEq(relayer.balance, relayerBalBefore + relayerFeeAmount);
        // Stealth balance is zero
        assertEq(stealth.getStealthBalance(stealthSigner, address(0)), 0);
    }

    function test_sp_relayerWithdraw_revertExpired() public {
        vm.prank(alice);
        stealth.sendNativeToStealth{value: 5 ether}(stealthAddr1, EPH_KEY_1, 0xAB, "");

        vm.warp(block.timestamp + 2 hours);

        vm.prank(relayer);
        vm.expectRevert("Expired");
        stealth.withdrawViaRelayer(
            stealthAddr1, address(0), bob, 0, block.timestamp - 1 hours,
            27, bytes32(0), bytes32(0)
        );
    }

    function test_sp_relayerWithdraw_revertZeroAddress() public {
        vm.prank(relayer);
        vm.expectRevert("Zero stealth addr");
        stealth.withdrawViaRelayer(
            address(0), address(0), bob, 0, block.timestamp + 1 hours,
            27, bytes32(0), bytes32(0)
        );
    }

    function test_sp_relayerWithdraw_revertFeeTooHigh() public {
        // Send 10 ether
        vm.prank(alice);
        stealth.sendNativeToStealth{value: 10 ether}(stealthAddr1, EPH_KEY_1, 0xAB, "");

        // 2% cap => max fee = 0.2 ether. Try 1 ether fee.
        vm.prank(relayer);
        vm.expectRevert("Fee too high");
        stealth.withdrawViaRelayer(
            stealthAddr1, address(0), bob, 1 ether, block.timestamp + 1 hours,
            27, bytes32(0), bytes32(0)
        );
    }

    function test_sp_setRelayerFeeCap() public {
        stealth.setRelayerFeeCap(300);
        assertEq(stealth.relayerFeeCap(), 300);
    }

    function test_sp_setRelayerFeeCap_revertTooHigh() public {
        vm.expectRevert("Fee cap too high");
        stealth.setRelayerFeeCap(600);
    }

    function test_sp_setRelayerFeeCap_revertNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        stealth.setRelayerFeeCap(100);
    }

    // =========================================================================
    // Gas Benchmarks
    // =========================================================================

    function test_gas_depositWithCommitment() public {
        bytes32 commitment = _computeCommitment(1 ether, BLINDING_1, alice);
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        vault.depositWithCommitment{value: 1 ether}(commitment);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas: depositWithCommitment (native):", gasUsed);
    }

    function test_gas_withdrawWithNullifier() public {
        bytes32 commitment = _computeCommitment(1 ether, BLINDING_1, alice);
        vm.prank(alice);
        vault.depositWithCommitment{value: 1 ether}(commitment);

        bytes32 nullifier = keccak256("gas-nullifier");
        uint256 gasBefore = gasleft();
        vault.withdrawWithNullifier(nullifier, 0, 1 ether, BLINDING_1, bob);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas: withdrawWithNullifier:", gasUsed);
    }

    function test_gas_batchSend3() public {
        IStealthVault.BatchStealthPayment[] memory payments = new IStealthVault.BatchStealthPayment[](3);
        payments[0] = IStealthVault.BatchStealthPayment(stealthAddr1, 1 ether, EPH_KEY_1, 0xAA);
        payments[1] = IStealthVault.BatchStealthPayment(stealthAddr2, 1 ether, EPH_KEY_2, 0xBB);
        payments[2] = IStealthVault.BatchStealthPayment(stealthAddr3, 1 ether, EPH_KEY_3, 0xCC);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        vault.batchSendNativeToStealth{value: 3 ether}(payments, "");
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas: batchSendNativeToStealth (3 recipients):", gasUsed);
    }

    function test_gas_computeViewTag() public view {
        uint256 gasBefore = gasleft();
        vault.computeViewTag(keccak256("secret"));
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas: computeViewTag:", gasUsed);
    }

    function test_gas_computeStealthAddress() public view {
        uint256 gasBefore = gasleft();
        vault.computeStealthAddress(keccak256("spend"), keccak256("secret"));
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas: computeStealthAddress:", gasUsed);
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    function _computeCommitment(
        uint256 amount,
        bytes32 blindingFactor,
        address depositor
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(amount, blindingFactor, depositor));
    }
}
