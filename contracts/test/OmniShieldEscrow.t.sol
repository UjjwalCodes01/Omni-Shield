// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {OmniShieldEscrow} from "../src/OmniShieldEscrow.sol";
import {IOmniShieldEscrow} from "../src/interfaces/IOmniShieldEscrow.sol";
import {TimelockAdmin} from "../src/TimelockAdmin.sol";

/// @title OmniShieldEscrowTest
/// @notice Comprehensive test suite for the Escrow contract
contract OmniShieldEscrowTest is Test {
    OmniShieldEscrow public escrow;

    address public owner = address(this);
    address public feeCollector = makeAddr("feeCollector");
    address public depositor = makeAddr("depositor");
    address public recipient = makeAddr("recipient");
    address public attacker = makeAddr("attacker");

    uint256 public constant FEE_BPS = 50; // 0.5%
    uint64 public constant DEFAULT_DURATION = 7 days;

    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed depositor,
        address indexed recipient,
        address token,
        uint256 amount,
        uint64 expiresAt,
        bytes32 releaseConditionHash
    );

    event EscrowReleased(uint256 indexed escrowId, address indexed recipient, uint256 amount, uint256 fee);
    event EscrowRefunded(uint256 indexed escrowId, address indexed depositor, uint256 amount);
    event EscrowDisputed(uint256 indexed escrowId, address indexed disputant);
    event DisputeResolved(uint256 indexed escrowId, bool releasedToRecipient);
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);
    event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event TimelockScheduled(bytes32 indexed opHash, uint64 readyAt);
    event TimelockExecuted(bytes32 indexed opHash);
    event TimelockCancelled(bytes32 indexed opHash);

    function setUp() public {
        escrow = new OmniShieldEscrow(feeCollector, FEE_BPS);
        vm.deal(depositor, 100 ether);
        vm.deal(recipient, 10 ether);
        vm.deal(attacker, 10 ether);
    }

    // =========================================================================
    // Helper
    // =========================================================================

    function _createDefaultEscrow() internal returns (uint256) {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;
        vm.prank(depositor);
        return escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));
    }

    // =========================================================================
    // Constructor Tests
    // =========================================================================

    function test_constructor_setsState() public view {
        assertEq(escrow.feeCollector(), feeCollector);
        assertEq(escrow.protocolFeeBps(), FEE_BPS);
        assertEq(escrow.owner(), owner);
        assertEq(escrow.getEscrowCount(), 0);
    }

    function test_constructor_revertZeroFeeCollector() public {
        vm.expectRevert(IOmniShieldEscrow.InvalidFeeCollector.selector);
        new OmniShieldEscrow(address(0), FEE_BPS);
    }

    function test_constructor_revertFeeTooHigh() public {
        vm.expectRevert(IOmniShieldEscrow.FeeTooHigh.selector);
        new OmniShieldEscrow(feeCollector, 501);
    }

    // =========================================================================
    // createEscrowNative Tests
    // =========================================================================

    function test_createEscrowNative_success() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;
        bytes32 condHash = keccak256("test-condition");

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, condHash);

        assertEq(escrowId, 0);
        assertEq(escrow.getEscrowCount(), 1);

        IOmniShieldEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(e.depositor, depositor);
        assertEq(e.recipient, recipient);
        assertEq(e.token, address(0));
        assertEq(uint8(e.state), uint8(IOmniShieldEscrow.EscrowState.Active));
        assertEq(e.expiresAt, expiry);
        assertEq(e.releaseConditionHash, condHash);

        // Check fee calculation: 1 ether * 50 / 10000 = 0.005 ether
        uint256 expectedFee = (1 ether * FEE_BPS) / 10_000;
        assertEq(e.fee, expectedFee);
        assertEq(e.amount, 1 ether - expectedFee);
    }

    function test_createEscrowNative_updatesActiveBalance() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;
        uint256 expectedFee = (1 ether * FEE_BPS) / 10_000;
        uint256 expectedNet = 1 ether - expectedFee;

        vm.prank(depositor);
        escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));

        // [W1] Verify totalActiveEscrowAmount is tracked
        assertEq(escrow.totalActiveEscrowAmount(address(0)), expectedNet);
    }

    function test_createEscrowNative_emitsEvent() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;
        uint256 expectedFee = (1 ether * FEE_BPS) / 10_000;
        uint256 expectedAmount = 1 ether - expectedFee;

        vm.expectEmit(true, true, true, true);
        emit EscrowCreated(0, depositor, recipient, address(0), expectedAmount, expiry, bytes32(0));

        vm.prank(depositor);
        escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));
    }

    function test_createEscrowNative_revertZeroRecipient() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        vm.expectRevert(IOmniShieldEscrow.InvalidRecipient.selector);
        escrow.createEscrowNative{value: 1 ether}(address(0), expiry, bytes32(0));
    }

    function test_createEscrowNative_revertSelfRecipient() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        vm.expectRevert(IOmniShieldEscrow.InvalidRecipient.selector);
        escrow.createEscrowNative{value: 1 ether}(depositor, expiry, bytes32(0));
    }

    function test_createEscrowNative_revertZeroAmount() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        vm.expectRevert(IOmniShieldEscrow.InvalidAmount.selector);
        escrow.createEscrowNative{value: 0}(recipient, expiry, bytes32(0));
    }

    function test_createEscrowNative_revertExpiryTooSoon() public {
        uint64 expiry = uint64(block.timestamp) + 30 minutes;

        vm.prank(depositor);
        vm.expectRevert(IOmniShieldEscrow.InvalidExpiry.selector);
        escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));
    }

    function test_createEscrowNative_revertExpiryTooFar() public {
        uint64 expiry = uint64(block.timestamp) + 366 days;

        vm.prank(depositor);
        vm.expectRevert(IOmniShieldEscrow.InvalidExpiry.selector);
        escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));
    }

    function test_createEscrowNative_revertWhenPaused() public {
        escrow.pause();
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        vm.expectRevert();
        escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));
    }

    function test_createEscrowNative_multipleEscrows() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.startPrank(depositor);
        uint256 id0 = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));
        uint256 id1 = escrow.createEscrowNative{value: 2 ether}(recipient, expiry, bytes32(0));
        vm.stopPrank();

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(escrow.getEscrowCount(), 2);
    }

    function test_createEscrowNative_tracksDepositorAndRecipientIds() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));

        uint256[] memory depositorEscrows = escrow.getDepositorEscrows(depositor);
        uint256[] memory recipientEscrows = escrow.getRecipientEscrows(recipient);

        assertEq(depositorEscrows.length, 1);
        assertEq(depositorEscrows[0], 0);
        assertEq(recipientEscrows.length, 1);
        assertEq(recipientEscrows[0], 0);
    }

    // =========================================================================
    // Release Tests
    // =========================================================================

    function test_release_successNoCondition() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));

        uint256 recipientBalBefore = recipient.balance;

        vm.prank(depositor);
        escrow.release(escrowId, "");

        IOmniShieldEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.state), uint8(IOmniShieldEscrow.EscrowState.Released));

        uint256 expectedFee = (1 ether * FEE_BPS) / 10_000;
        assertEq(recipient.balance, recipientBalBefore + 1 ether - expectedFee);

        // [W1] Active balance should be 0 after release
        assertEq(escrow.totalActiveEscrowAmount(address(0)), 0);
    }

    function test_release_successWithCondition() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;
        bytes memory conditionData = "secret-release-key";
        bytes32 condHash = keccak256(conditionData);

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, condHash);

        vm.prank(depositor);
        escrow.release(escrowId, conditionData);

        IOmniShieldEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.state), uint8(IOmniShieldEscrow.EscrowState.Released));
    }

    function test_release_revertWrongCondition() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;
        bytes32 condHash = keccak256("correct-key");

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, condHash);

        vm.prank(depositor);
        vm.expectRevert(IOmniShieldEscrow.InvalidCondition.selector);
        escrow.release(escrowId, "wrong-key");
    }

    function test_release_revertNotDepositor() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));

        vm.prank(recipient);
        vm.expectRevert(IOmniShieldEscrow.OnlyDepositor.selector);
        escrow.release(escrowId, "");

        vm.prank(attacker);
        vm.expectRevert(IOmniShieldEscrow.OnlyDepositor.selector);
        escrow.release(escrowId, "");
    }

    function test_release_revertNotActive() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));

        vm.prank(depositor);
        escrow.release(escrowId, "");

        vm.prank(depositor);
        vm.expectRevert(IOmniShieldEscrow.EscrowNotActive.selector);
        escrow.release(escrowId, "");
    }

    function test_release_emitsEvent() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;
        uint256 expectedFee = (1 ether * FEE_BPS) / 10_000;
        uint256 expectedAmount = 1 ether - expectedFee;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));

        vm.expectEmit(true, true, true, true);
        emit EscrowReleased(escrowId, recipient, expectedAmount, expectedFee);

        vm.prank(depositor);
        escrow.release(escrowId, "");
    }

    // =========================================================================
    // Refund Tests
    // =========================================================================

    function test_refund_successAfterExpiry() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));

        uint256 depositorBalBefore = depositor.balance;

        vm.warp(expiry + 1);
        escrow.refund(escrowId);

        IOmniShieldEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.state), uint8(IOmniShieldEscrow.EscrowState.Refunded));
        assertEq(depositor.balance, depositorBalBefore + 1 ether);

        // [W1] Active balance should be 0 after refund
        assertEq(escrow.totalActiveEscrowAmount(address(0)), 0);
    }

    function test_refund_revertBeforeExpiry() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));

        vm.expectRevert(IOmniShieldEscrow.EscrowNotExpired.selector);
        escrow.refund(escrowId);
    }

    function test_refund_reversesFeeAccumulation() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));

        uint256 expectedFee = (1 ether * FEE_BPS) / 10_000;
        assertEq(escrow.accumulatedFees(address(0)), expectedFee);

        vm.warp(expiry + 1);
        escrow.refund(escrowId);

        assertEq(escrow.accumulatedFees(address(0)), 0);
    }

    function test_refund_anyoneCanCallAfterExpiry() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));

        vm.warp(expiry + 1);

        vm.prank(attacker);
        escrow.refund(escrowId);

        IOmniShieldEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.state), uint8(IOmniShieldEscrow.EscrowState.Refunded));
    }

    // =========================================================================
    // Dispute Tests
    // =========================================================================

    function test_dispute_byDepositor() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));

        vm.expectEmit(true, true, true, true);
        emit EscrowDisputed(escrowId, depositor);

        vm.prank(depositor);
        escrow.dispute(escrowId);

        IOmniShieldEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.state), uint8(IOmniShieldEscrow.EscrowState.Disputed));

        // [W1] Disputed escrow still tracked as active
        uint256 expectedNet = 1 ether - ((1 ether * FEE_BPS) / 10_000);
        assertEq(escrow.totalActiveEscrowAmount(address(0)), expectedNet);
    }

    function test_dispute_byRecipient() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));

        vm.prank(recipient);
        escrow.dispute(escrowId);

        IOmniShieldEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.state), uint8(IOmniShieldEscrow.EscrowState.Disputed));
    }

    function test_dispute_revertByThirdParty() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));

        vm.prank(attacker);
        vm.expectRevert(IOmniShieldEscrow.OnlyDepositorOrRecipient.selector);
        escrow.dispute(escrowId);
    }

    // =========================================================================
    // resolveDispute Tests
    // =========================================================================

    function test_resolveDispute_releaseToRecipient() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));

        vm.prank(depositor);
        escrow.dispute(escrowId);

        uint256 recipientBalBefore = recipient.balance;
        uint256 expectedAmount = 1 ether - ((1 ether * FEE_BPS) / 10_000);

        escrow.resolveDispute(escrowId, true);

        assertEq(recipient.balance, recipientBalBefore + expectedAmount);

        IOmniShieldEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.state), uint8(IOmniShieldEscrow.EscrowState.Released));

        // [W1] Active balance should be 0 after resolution
        assertEq(escrow.totalActiveEscrowAmount(address(0)), 0);
    }

    function test_resolveDispute_refundToDepositor() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));

        vm.prank(depositor);
        escrow.dispute(escrowId);

        uint256 depositorBalBefore = depositor.balance;

        escrow.resolveDispute(escrowId, false);

        assertEq(depositor.balance, depositorBalBefore + 1 ether);

        IOmniShieldEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.state), uint8(IOmniShieldEscrow.EscrowState.Refunded));

        // [W1] Active balance should be 0
        assertEq(escrow.totalActiveEscrowAmount(address(0)), 0);
    }

    function test_resolveDispute_revertNotOwner() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));

        vm.prank(depositor);
        escrow.dispute(escrowId);

        vm.prank(attacker);
        vm.expectRevert();
        escrow.resolveDispute(escrowId, true);
    }

    function test_resolveDispute_revertNotDisputed() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));

        vm.expectRevert(IOmniShieldEscrow.EscrowNotDisputed.selector);
        escrow.resolveDispute(escrowId, true);
    }

    // =========================================================================
    // [W3] Timelock Tests — Fee Collector
    // =========================================================================

    function test_scheduleFeeCollectorChange_success() public {
        address newCollector = makeAddr("newCollector");
        bytes32 opHash = keccak256(abi.encode("setFeeCollector", newCollector));

        vm.expectEmit(true, true, true, true);
        emit TimelockScheduled(opHash, uint64(block.timestamp) + 2 hours);

        escrow.scheduleFeeCollectorChange(newCollector);

        assertGt(escrow.timelockReady(opHash), 0);
    }

    function test_scheduleFeeCollectorChange_revertZeroAddress() public {
        vm.expectRevert(IOmniShieldEscrow.InvalidFeeCollector.selector);
        escrow.scheduleFeeCollectorChange(address(0));
    }

    function test_scheduleFeeCollectorChange_revertNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        escrow.scheduleFeeCollectorChange(makeAddr("x"));
    }

    function test_executeFeeCollectorChange_success() public {
        address newCollector = makeAddr("newCollector");

        escrow.scheduleFeeCollectorChange(newCollector);
        vm.warp(block.timestamp + 2 hours + 1);

        vm.expectEmit(true, true, true, true);
        emit FeeCollectorUpdated(feeCollector, newCollector);

        escrow.executeFeeCollectorChange(newCollector);
        assertEq(escrow.feeCollector(), newCollector);
    }

    function test_executeFeeCollectorChange_revertTooEarly() public {
        address newCollector = makeAddr("newCollector");
        escrow.scheduleFeeCollectorChange(newCollector);

        // Only 1 hour passed, need 2
        vm.warp(block.timestamp + 1 hours);

        vm.expectRevert(TimelockAdmin.TimelockNotReady.selector);
        escrow.executeFeeCollectorChange(newCollector);
    }

    function test_executeFeeCollectorChange_revertNotScheduled() public {
        vm.expectRevert(TimelockAdmin.TimelockNotScheduled.selector);
        escrow.executeFeeCollectorChange(makeAddr("random"));
    }

    function test_executeFeeCollectorChange_revertDoubleSchedule() public {
        address newCollector = makeAddr("newCollector");
        escrow.scheduleFeeCollectorChange(newCollector);

        vm.expectRevert(TimelockAdmin.TimelockAlreadyScheduled.selector);
        escrow.scheduleFeeCollectorChange(newCollector);
    }

    // =========================================================================
    // [W3] Timelock Tests — Protocol Fee
    // =========================================================================

    function test_scheduleProtocolFeeChange_success() public {
        uint256 newFee = 100; // 1%
        bytes32 opHash = keccak256(abi.encode("setProtocolFee", newFee));

        escrow.scheduleProtocolFeeChange(newFee);
        assertGt(escrow.timelockReady(opHash), 0);
    }

    function test_scheduleProtocolFeeChange_revertTooHigh() public {
        vm.expectRevert(IOmniShieldEscrow.FeeTooHigh.selector);
        escrow.scheduleProtocolFeeChange(501);
    }

    function test_executeProtocolFeeChange_success() public {
        uint256 newFee = 100;
        escrow.scheduleProtocolFeeChange(newFee);
        vm.warp(block.timestamp + 2 hours + 1);

        escrow.executeProtocolFeeChange(newFee);
        assertEq(escrow.protocolFeeBps(), newFee);
    }

    function test_executeProtocolFeeChange_revertTooEarly() public {
        escrow.scheduleProtocolFeeChange(100);
        vm.warp(block.timestamp + 30 minutes);

        vm.expectRevert(TimelockAdmin.TimelockNotReady.selector);
        escrow.executeProtocolFeeChange(100);
    }

    // =========================================================================
    // [W3] Timelock Tests — Cancel
    // =========================================================================

    function test_cancelTimelock_success() public {
        address newCollector = makeAddr("newCollector");
        bytes32 opHash = keccak256(abi.encode("setFeeCollector", newCollector));

        escrow.scheduleFeeCollectorChange(newCollector);
        assertGt(escrow.timelockReady(opHash), 0);

        vm.expectEmit(true, true, true, true);
        emit TimelockCancelled(opHash);

        escrow.cancelTimelock(opHash);
        assertEq(escrow.timelockReady(opHash), 0);
    }

    function test_cancelTimelock_revertNotScheduled() public {
        bytes32 bogusHash = keccak256("bogus");
        vm.expectRevert(TimelockAdmin.TimelockNotScheduled.selector);
        escrow.cancelTimelock(bogusHash);
    }

    function test_cancelTimelock_revertNotOwner() public {
        address newCollector = makeAddr("newCollector");
        escrow.scheduleFeeCollectorChange(newCollector);

        bytes32 opHash = keccak256(abi.encode("setFeeCollector", newCollector));
        vm.prank(attacker);
        vm.expectRevert();
        escrow.cancelTimelock(opHash);
    }

    // =========================================================================
    // [W1] Emergency Withdraw — Balance Accounting Tests
    // =========================================================================

    function test_emergencyWithdraw_revertExceedsAvailable() public {
        // Create an active escrow
        _createDefaultEscrow();

        // Try to withdraw the escrow funds — should fail
        vm.expectRevert(IOmniShieldEscrow.ExceedsAvailableBalance.selector);
        escrow.emergencyWithdraw(address(0), 1 ether);
    }

    function test_emergencyWithdraw_onlyExcessFunds() public {
        // Create an active escrow worth 1 ETH
        _createDefaultEscrow();

        // Send 0.5 ETH of "stuck" tokens directly (bypasses receive by using selfdestruct)
        StuckFundsSender sender = new StuckFundsSender();
        vm.deal(address(sender), 0.5 ether);
        sender.destroy(payable(address(escrow)));

        // Now contract has 1 ETH (escrow) + 0.5 ETH (stuck) = 1.5 ETH
        assertEq(address(escrow).balance, 1.5 ether);

        // Owner can withdraw the 0.5 ETH stuck funds
        uint256 ownerBalBefore = owner.balance;
        escrow.emergencyWithdraw(address(0), 0.5 ether);
        assertEq(owner.balance, ownerBalBefore + 0.5 ether);

        // But cannot withdraw more than stuck amount
        vm.expectRevert(IOmniShieldEscrow.ExceedsAvailableBalance.selector);
        escrow.emergencyWithdraw(address(0), 1 wei);
    }

    function test_emergencyWithdraw_afterRelease() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));

        // Release the escrow — net goes to recipient, fee stays
        vm.prank(depositor);
        escrow.release(escrowId, "");

        // Now only accumulated fees remain (protected)
        uint256 expectedFee = (1 ether * FEE_BPS) / 10_000;
        assertEq(address(escrow).balance, expectedFee);

        // Cannot withdraw fees
        vm.expectRevert(IOmniShieldEscrow.ExceedsAvailableBalance.selector);
        escrow.emergencyWithdraw(address(0), 1 wei);
    }

    function test_emergencyWithdraw_zeroActiveAllowsStuck() public {
        // No active escrows, no fees
        // Send stuck ETH directly
        StuckFundsSender sender = new StuckFundsSender();
        vm.deal(address(sender), 1 ether);
        sender.destroy(payable(address(escrow)));

        uint256 ownerBalBefore = owner.balance;
        escrow.emergencyWithdraw(address(0), 1 ether);
        assertEq(owner.balance, ownerBalBefore + 1 ether);
    }

    // =========================================================================
    // [W5] Pagination Tests
    // =========================================================================

    function test_getDepositorEscrowsPaginated() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        // Create 5 escrows
        vm.startPrank(depositor);
        for (uint256 i = 0; i < 5; i++) {
            escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));
        }
        vm.stopPrank();

        // Page 1: offset=0, limit=2
        (uint256[] memory page1, uint256 total1) = escrow.getDepositorEscrowsPaginated(depositor, 0, 2);
        assertEq(total1, 5);
        assertEq(page1.length, 2);
        assertEq(page1[0], 0);
        assertEq(page1[1], 1);

        // Page 2: offset=2, limit=2
        (uint256[] memory page2, uint256 total2) = escrow.getDepositorEscrowsPaginated(depositor, 2, 2);
        assertEq(total2, 5);
        assertEq(page2.length, 2);
        assertEq(page2[0], 2);
        assertEq(page2[1], 3);

        // Page 3: offset=4, limit=2 (partial)
        (uint256[] memory page3, uint256 total3) = escrow.getDepositorEscrowsPaginated(depositor, 4, 2);
        assertEq(total3, 5);
        assertEq(page3.length, 1);
        assertEq(page3[0], 4);

        // Out of bounds
        (uint256[] memory page4, uint256 total4) = escrow.getDepositorEscrowsPaginated(depositor, 10, 2);
        assertEq(total4, 5);
        assertEq(page4.length, 0);
    }

    function test_getRecipientEscrowsPaginated() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.startPrank(depositor);
        for (uint256 i = 0; i < 3; i++) {
            escrow.createEscrowNative{value: 1 ether}(recipient, expiry, bytes32(0));
        }
        vm.stopPrank();

        (uint256[] memory ids, uint256 total) = escrow.getRecipientEscrowsPaginated(recipient, 0, 10);
        assertEq(total, 3);
        assertEq(ids.length, 3);
    }

    // =========================================================================
    // Fee Withdrawal Test
    // =========================================================================

    function test_withdrawFees() public {
        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 10 ether}(recipient, expiry, bytes32(0));

        vm.prank(depositor);
        escrow.release(escrowId, "");

        uint256 expectedFee = (10 ether * FEE_BPS) / 10_000;
        uint256 collectorBalBefore = feeCollector.balance;

        escrow.withdrawFees(address(0));

        assertEq(feeCollector.balance, collectorBalBefore + expectedFee);
        assertEq(escrow.accumulatedFees(address(0)), 0);
    }

    function test_pauseUnpause() public {
        escrow.pause();
        assertTrue(escrow.paused());

        escrow.unpause();
        assertFalse(escrow.paused());
    }

    // =========================================================================
    // Reentrancy Protection Test
    // =========================================================================

    function test_release_reentrancyProtection() public {
        ReentrancyAttacker attackerContract = new ReentrancyAttacker(address(escrow));
        vm.deal(depositor, 10 ether);

        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: 5 ether}(
            address(attackerContract),
            expiry,
            bytes32(0)
        );

        attackerContract.setTargetEscrowId(escrowId);

        vm.prank(depositor);
        escrow.release(escrowId, "");

        IOmniShieldEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.state), uint8(IOmniShieldEscrow.EscrowState.Released));
    }

    // =========================================================================
    // Receive Test
    // =========================================================================

    function test_receive_revertDirectTransfer() public {
        vm.prank(depositor);
        vm.expectRevert("Use createEscrowNative");
        (bool success,) = address(escrow).call{value: 1 ether}("");
        success;
    }

    // =========================================================================
    // Fuzz Tests
    // =========================================================================

    function testFuzz_createEscrowNative_feeCalculation(uint256 amount) public {
        amount = bound(amount, 0.01 ether, 1_000_000 ether);
        vm.deal(depositor, amount);

        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: amount}(recipient, expiry, bytes32(0));

        IOmniShieldEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        uint256 expectedFee = (amount * FEE_BPS) / 10_000;

        assertEq(e.fee, expectedFee);
        assertEq(e.amount, amount - expectedFee);
        assertEq(e.amount + e.fee, amount);
    }

    function testFuzz_createAndRelease_noValueLeak(uint256 amount) public {
        amount = bound(amount, 0.01 ether, 1_000_000 ether);
        vm.deal(depositor, amount);

        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;

        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowNative{value: amount}(recipient, expiry, bytes32(0));

        uint256 recipientBefore = recipient.balance;

        vm.prank(depositor);
        escrow.release(escrowId, "");

        IOmniShieldEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        uint256 recipientReceived = recipient.balance - recipientBefore;

        assertEq(recipientReceived, e.amount);
        assertEq(address(escrow).balance, e.fee);

        // [W1] Verify active balance is 0 after release
        assertEq(escrow.totalActiveEscrowAmount(address(0)), 0);
    }

    function testFuzz_W1_emergencyCannotTouchActive(uint256 amount) public {
        amount = bound(amount, 0.01 ether, 100 ether);
        vm.deal(depositor, amount);

        uint64 expiry = uint64(block.timestamp) + DEFAULT_DURATION;
        vm.prank(depositor);
        escrow.createEscrowNative{value: amount}(recipient, expiry, bytes32(0));

        // Any emergency withdraw should fail since all funds are protected
        vm.expectRevert(IOmniShieldEscrow.ExceedsAvailableBalance.selector);
        escrow.emergencyWithdraw(address(0), 1 wei);
    }

    // Allow test contract (owner) to receive ETH from emergencyWithdraw
    receive() external payable {}
}

/// @notice Helper to send ETH directly to contract (bypassing receive) via selfdestruct
contract StuckFundsSender {
    function destroy(address payable target) external {
        selfdestruct(target);
    }
}

/// @notice Malicious contract that attempts reentrancy on release
contract ReentrancyAttacker {
    OmniShieldEscrow public escrow;
    uint256 public targetEscrowId;
    bool public attacked;

    constructor(address _escrow) {
        escrow = OmniShieldEscrow(payable(_escrow));
    }

    function setTargetEscrowId(uint256 _id) external {
        targetEscrowId = _id;
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            try escrow.release(targetEscrowId, "") {} catch {}
        }
    }
}
