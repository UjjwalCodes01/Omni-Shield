// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {XcmRouter} from "../src/XcmRouter.sol";
import {XcmTypes} from "../src/libraries/XcmTypes.sol";
import {XcmBuilder} from "../src/libraries/XcmBuilder.sol";
import {IXcmPrecompile} from "../src/interfaces/IXcmPrecompile.sol";

/// @title XcmRouterTest
/// @notice Comprehensive test suite for the XCM Router contract
/// @dev Tests cover dispatch lifecycle, relayer confirmations, timeout handling,
///      access control, admin functions, and XcmBuilder library
contract XcmRouterTest is Test {
    XcmRouter public router;

    address public owner = address(this);
    address public relayer = makeAddr("relayer");
    address public relayer2 = makeAddr("relayer2");
    address public caller = makeAddr("yieldRouter"); // authorized caller
    address public alice = makeAddr("alice");
    address public attacker = makeAddr("attacker");

    uint32 public constant BIFROST_PARA_ID = 2030;
    uint32 public constant HYDRADX_PARA_ID = 2034;
    uint32 public constant ACALA_PARA_ID = 2000;

    // Events (must match XcmRouter events for expectEmit)
    event XcmDispatched(
        uint256 indexed dispatchId,
        uint256 indexed routeId,
        uint32 indexed paraId,
        uint256 amount,
        bytes32 xcmMessageHash
    );
    event XcmConfirmed(uint256 indexed dispatchId, uint256 indexed routeId, uint32 paraId);
    event XcmFailed(uint256 indexed dispatchId, uint256 indexed routeId, uint32 paraId, string reason);
    event XcmTimedOut(uint256 indexed dispatchId, uint256 indexed routeId);
    event XcmReturnInitiated(uint256 indexed dispatchId, uint256 indexed routeId, uint256 amount, uint256 yieldEarned);
    event XcmReturnConfirmed(uint256 indexed dispatchId, uint256 indexed routeId, uint256 amountReturned);
    event CallerAuthorized(address indexed caller);
    event CallerRevoked(address indexed caller);
    event RelayerAuthorized(address indexed relayer);
    event RelayerRevoked(address indexed relayer);
    event BeneficiaryConfigured(uint32 indexed paraId, bytes32 beneficiary);
    event RouteConfigured(uint32 indexed paraId, uint64 weightRefTime, uint64 weightProofSize);
    event PrecompileStatusUpdated(bool available);

    function setUp() public {
        router = new XcmRouter(relayer);
        vm.deal(caller, 1000 ether);
        vm.deal(alice, 100 ether);
        vm.deal(attacker, 10 ether);

        // Authorize caller (simulates YieldRouter)
        router.authorizeCaller(caller);
    }

    // =========================================================================
    // Helper: dispatch funds as authorized caller
    // =========================================================================

    function _dispatch(uint256 routeId, uint32 paraId, uint256 amount)
        internal
        returns (uint256 dispatchId)
    {
        vm.prank(caller);
        dispatchId = router.dispatchToParachain{value: amount}(routeId, paraId, amount);
    }

    // =========================================================================
    // Constructor Tests
    // =========================================================================

    function test_constructor_setsState() public view {
        assertTrue(router.isAuthorizedRelayer(relayer));
        assertEq(router.relayerCount(), 1);
        assertFalse(router.xcmPrecompileAvailable());
        assertEq(router.pendingDispatches(), 0);
        assertEq(router.amountInTransit(), 0);
    }

    function test_constructor_revertZeroRelayer() public {
        vm.expectRevert(XcmRouter.OnlyAuthorizedRelayer.selector);
        new XcmRouter(address(0));
    }

    function test_constructor_emitsEvents() public {
        vm.expectEmit(true, false, false, false);
        emit RelayerAuthorized(relayer);
        vm.expectEmit(false, false, false, true);
        emit PrecompileStatusUpdated(false);
        new XcmRouter(relayer);
    }

    // =========================================================================
    // Dispatch Tests
    // =========================================================================

    function test_dispatch_success() public {
        uint256 dispatchId = _dispatch(1, BIFROST_PARA_ID, 1 ether);
        assertEq(dispatchId, 1);
        assertEq(router.pendingDispatches(), 1);
        assertEq(router.amountInTransit(), 1 ether);
        assertEq(router.routeToDispatch(1), 1);

        XcmTypes.XcmDispatch memory d = router.getDispatch(1);
        assertEq(d.routeId, 1);
        assertEq(d.paraId, BIFROST_PARA_ID);
        assertEq(d.amount, 1 ether);
        assertTrue(d.status == XcmTypes.XcmStatus.Pending);
        assertTrue(d.xcmMessageHash != bytes32(0));
        assertEq(d.dispatchedAt, block.timestamp);
        assertEq(d.confirmedAt, 0);
        assertEq(d.timeoutAt, uint64(block.timestamp) + 6 hours);
    }

    function test_dispatch_emitsEvent() public {
        vm.expectEmit(true, true, true, false);
        emit XcmDispatched(1, 1, BIFROST_PARA_ID, 1 ether, bytes32(0)); // hash is non-deterministic
        _dispatch(1, BIFROST_PARA_ID, 1 ether);
    }

    function test_dispatch_multipleDispatches() public {
        uint256 id1 = _dispatch(1, BIFROST_PARA_ID, 1 ether);
        uint256 id2 = _dispatch(2, HYDRADX_PARA_ID, 2 ether);
        uint256 id3 = _dispatch(3, ACALA_PARA_ID, 0.5 ether);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
        assertEq(router.pendingDispatches(), 3);
        assertEq(router.amountInTransit(), 3.5 ether);
        assertEq(router.getDispatchCount(), 3);
    }

    function test_dispatch_holdsEtherInContract() public {
        uint256 balBefore = address(router).balance;
        _dispatch(1, BIFROST_PARA_ID, 5 ether);
        assertEq(address(router).balance, balBefore + 5 ether);
    }

    function test_dispatch_usesDefaultBeneficiary() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);
        XcmTypes.XcmDispatch memory d = router.getDispatch(1);
        // Default beneficiary is owner padded to bytes32
        // Just verify the dispatch succeeded with non-zero hash
        assertTrue(d.xcmMessageHash != bytes32(0));
    }

    function test_dispatch_usesConfiguredBeneficiary() public {
        bytes32 vault = bytes32(uint256(0xDEAD));
        router.setParachainBeneficiary(BIFROST_PARA_ID, vault);

        _dispatch(1, BIFROST_PARA_ID, 1 ether);
        XcmTypes.XcmDispatch memory d = router.getDispatch(1);
        assertTrue(d.xcmMessageHash != bytes32(0));
    }

    function test_dispatch_revertZeroParachain() public {
        vm.prank(caller);
        vm.expectRevert(XcmRouter.InvalidParachain.selector);
        router.dispatchToParachain{value: 1 ether}(1, 0, 1 ether);
    }

    function test_dispatch_revertZeroAmount() public {
        vm.prank(caller);
        vm.expectRevert(XcmRouter.InvalidAmount.selector);
        router.dispatchToParachain{value: 0}(1, BIFROST_PARA_ID, 0);
    }

    function test_dispatch_revertInsufficientValue() public {
        vm.prank(caller);
        vm.expectRevert(XcmRouter.InvalidAmount.selector);
        router.dispatchToParachain{value: 0.5 ether}(1, BIFROST_PARA_ID, 1 ether);
    }

    function test_dispatch_revertNotAuthorizedCaller() public {
        vm.prank(attacker);
        vm.expectRevert(XcmRouter.OnlyAuthorizedCaller.selector);
        router.dispatchToParachain{value: 1 ether}(1, BIFROST_PARA_ID, 1 ether);
    }

    function test_dispatch_revertWhenPaused() public {
        router.pause();
        vm.prank(caller);
        vm.expectRevert();
        router.dispatchToParachain{value: 1 ether}(1, BIFROST_PARA_ID, 1 ether);
    }

    function test_dispatch_revertDuplicateRoute() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);

        vm.prank(caller);
        vm.expectRevert(XcmRouter.RouteAlreadyDispatched.selector);
        router.dispatchToParachain{value: 1 ether}(1, BIFROST_PARA_ID, 1 ether);
    }

    function testFuzz_dispatch_anyAmount(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        vm.deal(caller, amount);

        vm.prank(caller);
        uint256 dispatchId = router.dispatchToParachain{value: amount}(1, BIFROST_PARA_ID, amount);
        assertEq(dispatchId, 1);

        XcmTypes.XcmDispatch memory d = router.getDispatch(1);
        assertEq(d.amount, amount);
        assertEq(router.amountInTransit(), amount);
    }

    // =========================================================================
    // Confirm Dispatch Tests
    // =========================================================================

    function test_confirmDispatch_success() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);

        vm.prank(relayer);
        router.confirmDispatch(1);

        XcmTypes.XcmDispatch memory d = router.getDispatch(1);
        assertTrue(d.status == XcmTypes.XcmStatus.Confirmed);
        assertEq(d.confirmedAt, block.timestamp);
        assertEq(router.pendingDispatches(), 0);
        assertEq(router.amountInTransit(), 0);
    }

    function test_confirmDispatch_emitsEvent() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);

        vm.expectEmit(true, true, false, true);
        emit XcmConfirmed(1, 1, BIFROST_PARA_ID);
        vm.prank(relayer);
        router.confirmDispatch(1);
    }

    function test_confirmDispatch_revertNotRelayer() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);

        vm.prank(attacker);
        vm.expectRevert(XcmRouter.OnlyAuthorizedRelayer.selector);
        router.confirmDispatch(1);
    }

    function test_confirmDispatch_revertNotFound() public {
        vm.prank(relayer);
        vm.expectRevert(XcmRouter.DispatchNotFound.selector);
        router.confirmDispatch(999);
    }

    function test_confirmDispatch_revertAlreadyConfirmed() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);

        vm.prank(relayer);
        router.confirmDispatch(1);

        vm.prank(relayer);
        vm.expectRevert(XcmRouter.DispatchNotPending.selector);
        router.confirmDispatch(1);
    }

    function test_confirmDispatch_updatesCounters() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);
        _dispatch(2, HYDRADX_PARA_ID, 2 ether);
        assertEq(router.pendingDispatches(), 2);
        assertEq(router.amountInTransit(), 3 ether);

        vm.prank(relayer);
        router.confirmDispatch(1);
        assertEq(router.pendingDispatches(), 1);
        assertEq(router.amountInTransit(), 2 ether);

        vm.prank(relayer);
        router.confirmDispatch(2);
        assertEq(router.pendingDispatches(), 0);
        assertEq(router.amountInTransit(), 0);
    }

    // =========================================================================
    // Mark Failed Tests
    // =========================================================================

    function test_markFailed_success() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);

        vm.prank(relayer);
        router.markDispatchFailed(1, "XCM execution reverted on Bifrost");

        XcmTypes.XcmDispatch memory d = router.getDispatch(1);
        assertTrue(d.status == XcmTypes.XcmStatus.Failed);
        assertEq(router.pendingDispatches(), 0);
        assertEq(router.amountInTransit(), 0);
    }

    function test_markFailed_emitsEvent() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);

        vm.expectEmit(true, true, false, true);
        emit XcmFailed(1, 1, BIFROST_PARA_ID, "execution failed");
        vm.prank(relayer);
        router.markDispatchFailed(1, "execution failed");
    }

    function test_markFailed_revertNotRelayer() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);

        vm.prank(attacker);
        vm.expectRevert(XcmRouter.OnlyAuthorizedRelayer.selector);
        router.markDispatchFailed(1, "fail");
    }

    function test_markFailed_revertNotPending() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);

        vm.prank(relayer);
        router.confirmDispatch(1);

        vm.prank(relayer);
        vm.expectRevert(XcmRouter.DispatchNotPending.selector);
        router.markDispatchFailed(1, "too late");
    }

    // =========================================================================
    // Timeout Tests
    // =========================================================================

    function test_markTimedOut_success() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);

        // Advance past timeout (6 hours)
        vm.warp(block.timestamp + 6 hours);

        router.markTimedOut(1); // anyone can call

        XcmTypes.XcmDispatch memory d = router.getDispatch(1);
        assertTrue(d.status == XcmTypes.XcmStatus.TimedOut);
        assertEq(router.pendingDispatches(), 0);
        assertEq(router.amountInTransit(), 0);
    }

    function test_markTimedOut_emitsEvent() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);
        vm.warp(block.timestamp + 6 hours);

        vm.expectEmit(true, true, false, false);
        emit XcmTimedOut(1, 1);
        router.markTimedOut(1);
    }

    function test_markTimedOut_revertBeforeTimeout() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);

        // Only 3 hours have passed
        vm.warp(block.timestamp + 3 hours);

        vm.expectRevert(XcmRouter.DispatchNotPending.selector);
        router.markTimedOut(1);
    }

    function test_markTimedOut_anyoneCanCall() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);
        vm.warp(block.timestamp + 6 hours);

        // Non-relayer, non-owner can call
        vm.prank(attacker);
        router.markTimedOut(1);

        XcmTypes.XcmDispatch memory d = router.getDispatch(1);
        assertTrue(d.status == XcmTypes.XcmStatus.TimedOut);
    }

    function test_markTimedOut_revertNotPending() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);

        vm.prank(relayer);
        router.confirmDispatch(1);

        vm.warp(block.timestamp + 6 hours);
        vm.expectRevert(XcmRouter.DispatchNotPending.selector);
        router.markTimedOut(1);
    }

    function test_isTimedOut_view() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);
        assertFalse(router.isTimedOut(1));

        vm.warp(block.timestamp + 6 hours);
        assertTrue(router.isTimedOut(1));
    }

    // =========================================================================
    // Return (Withdrawal) Tests
    // =========================================================================

    function test_initiateReturn_success() public {
        _dispatch(1, BIFROST_PARA_ID, 10 ether);
        vm.prank(relayer);
        router.confirmDispatch(1);

        vm.expectEmit(true, true, false, true);
        emit XcmReturnInitiated(1, 1, 10 ether, 0.5 ether);
        vm.prank(relayer);
        router.initiateReturn(1, 0.5 ether);
    }

    function test_initiateReturn_revertNotConfirmed() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);

        // Still Pending — not confirmed yet
        vm.prank(relayer);
        vm.expectRevert(XcmRouter.DispatchNotPending.selector);
        router.initiateReturn(1, 0);
    }

    function test_initiateReturn_revertNotRelayer() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);
        vm.prank(relayer);
        router.confirmDispatch(1);

        vm.prank(attacker);
        vm.expectRevert(XcmRouter.OnlyAuthorizedRelayer.selector);
        router.initiateReturn(1, 0);
    }

    function test_confirmReturn_success() public {
        _dispatch(1, BIFROST_PARA_ID, 10 ether);
        vm.prank(relayer);
        router.confirmDispatch(1);
        vm.prank(relayer);
        router.initiateReturn(1, 0.5 ether);

        vm.expectEmit(true, true, false, true);
        emit XcmReturnConfirmed(1, 1, 10.5 ether);
        vm.deal(relayer, 10.5 ether);
        vm.prank(relayer);
        router.confirmReturn{value: 10.5 ether}(1);
    }

    function test_confirmReturn_revertNotRelayer() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);
        vm.prank(relayer);
        router.confirmDispatch(1);

        vm.prank(attacker);
        vm.expectRevert(XcmRouter.OnlyAuthorizedRelayer.selector);
        router.confirmReturn(1);
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    function test_getDispatch_returnsCorrectData() public {
        _dispatch(1, BIFROST_PARA_ID, 5 ether);

        XcmTypes.XcmDispatch memory d = router.getDispatch(1);
        assertEq(d.routeId, 1);
        assertEq(d.paraId, BIFROST_PARA_ID);
        assertEq(d.amount, 5 ether);
        assertTrue(d.status == XcmTypes.XcmStatus.Pending);
    }

    function test_getDispatchForRoute() public {
        _dispatch(42, BIFROST_PARA_ID, 1 ether);
        assertEq(router.getDispatchForRoute(42), 1);
    }

    function test_getDispatchCount() public {
        assertEq(router.getDispatchCount(), 0);
        _dispatch(1, BIFROST_PARA_ID, 1 ether);
        assertEq(router.getDispatchCount(), 1);
        _dispatch(2, HYDRADX_PARA_ID, 1 ether);
        assertEq(router.getDispatchCount(), 2);
    }

    // =========================================================================
    // Caller Authorization Tests
    // =========================================================================

    function test_authorizeCaller_success() public {
        address newCaller = makeAddr("newCaller");
        vm.expectEmit(true, false, false, false);
        emit CallerAuthorized(newCaller);
        router.authorizeCaller(newCaller);
        assertTrue(router.isAuthorizedCaller(newCaller));
    }

    function test_authorizeCaller_revertZeroAddress() public {
        vm.expectRevert(XcmRouter.OnlyAuthorizedCaller.selector);
        router.authorizeCaller(address(0));
    }

    function test_authorizeCaller_revertAlreadyAuthorized() public {
        vm.expectRevert(XcmRouter.AlreadyAuthorized.selector);
        router.authorizeCaller(caller); // already authorized in setUp
    }

    function test_authorizeCaller_revertNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        router.authorizeCaller(attacker);
    }

    function test_revokeCaller_success() public {
        vm.expectEmit(true, false, false, false);
        emit CallerRevoked(caller);
        router.revokeCaller(caller);
        assertFalse(router.isAuthorizedCaller(caller));
    }

    function test_revokeCaller_revertNotAuthorized() public {
        vm.expectRevert(XcmRouter.NotAuthorized.selector);
        router.revokeCaller(alice);
    }

    function test_revokeCaller_preventsDispatch() public {
        router.revokeCaller(caller);

        vm.prank(caller);
        vm.expectRevert(XcmRouter.OnlyAuthorizedCaller.selector);
        router.dispatchToParachain{value: 1 ether}(1, BIFROST_PARA_ID, 1 ether);
    }

    // =========================================================================
    // Relayer Authorization Tests
    // =========================================================================

    function test_addRelayer_success() public {
        vm.expectEmit(true, false, false, false);
        emit RelayerAuthorized(relayer2);
        router.addRelayer(relayer2);
        assertTrue(router.isAuthorizedRelayer(relayer2));
        assertEq(router.relayerCount(), 2);
    }

    function test_addRelayer_revertZeroAddress() public {
        vm.expectRevert(XcmRouter.OnlyAuthorizedRelayer.selector);
        router.addRelayer(address(0));
    }

    function test_addRelayer_revertAlreadyAuthorized() public {
        vm.expectRevert(XcmRouter.AlreadyAuthorized.selector);
        router.addRelayer(relayer); // already authorized
    }

    function test_addRelayer_revertNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        router.addRelayer(relayer2);
    }

    function test_removeRelayer_success() public {
        router.addRelayer(relayer2);
        assertEq(router.relayerCount(), 2);

        vm.expectEmit(true, false, false, false);
        emit RelayerRevoked(relayer);
        router.removeRelayer(relayer);
        assertFalse(router.isAuthorizedRelayer(relayer));
        assertEq(router.relayerCount(), 1);
    }

    function test_removeRelayer_revertLastRelayer() public {
        vm.expectRevert(XcmRouter.CannotRemoveLastRelayer.selector);
        router.removeRelayer(relayer); // only 1 relayer
    }

    function test_removeRelayer_revertNotAuthorized() public {
        vm.expectRevert(XcmRouter.NotAuthorized.selector);
        router.removeRelayer(alice);
    }

    function test_multiRelayer_bothCanConfirm() public {
        router.addRelayer(relayer2);

        _dispatch(1, BIFROST_PARA_ID, 1 ether);
        _dispatch(2, HYDRADX_PARA_ID, 2 ether);

        vm.prank(relayer);
        router.confirmDispatch(1);

        vm.prank(relayer2);
        router.confirmDispatch(2);

        assertTrue(router.getDispatch(1).status == XcmTypes.XcmStatus.Confirmed);
        assertTrue(router.getDispatch(2).status == XcmTypes.XcmStatus.Confirmed);
    }

    function test_removedRelayer_cannotConfirm() public {
        router.addRelayer(relayer2);
        router.removeRelayer(relayer);

        _dispatch(1, BIFROST_PARA_ID, 1 ether);

        vm.prank(relayer);
        vm.expectRevert(XcmRouter.OnlyAuthorizedRelayer.selector);
        router.confirmDispatch(1);
    }

    // =========================================================================
    // Beneficiary & Route Config Tests
    // =========================================================================

    function test_setParachainBeneficiary_success() public {
        bytes32 vault = keccak256("bifrost-vault");
        vm.expectEmit(true, false, false, true);
        emit BeneficiaryConfigured(BIFROST_PARA_ID, vault);
        router.setParachainBeneficiary(BIFROST_PARA_ID, vault);
        assertEq(router.parachainBeneficiary(BIFROST_PARA_ID), vault);
    }

    function test_setParachainBeneficiary_revertZeroParaId() public {
        vm.expectRevert(XcmRouter.InvalidParachain.selector);
        router.setParachainBeneficiary(0, bytes32(uint256(1)));
    }

    function test_setParachainBeneficiary_revertZeroBeneficiary() public {
        vm.expectRevert(XcmRouter.InvalidBeneficiary.selector);
        router.setParachainBeneficiary(BIFROST_PARA_ID, bytes32(0));
    }

    function test_setRouteConfig_success() public {
        vm.expectEmit(true, false, false, true);
        emit RouteConfigured(BIFROST_PARA_ID, 2_000_000_000, 131_072);
        router.setRouteConfig(BIFROST_PARA_ID, 2_000_000_000, 131_072);

        (uint32 paraId, , uint64 refTime, uint64 proofSize) = router.parachainRouteConfig(BIFROST_PARA_ID);
        assertEq(paraId, BIFROST_PARA_ID);
        assertEq(refTime, 2_000_000_000);
        assertEq(proofSize, 131_072);
    }

    function test_setRouteConfig_revertZeroParaId() public {
        vm.expectRevert(XcmRouter.InvalidParachain.selector);
        router.setRouteConfig(0, 1_000_000_000, 65_536);
    }

    // =========================================================================
    // Precompile Status Tests
    // =========================================================================

    function test_precompileNotAvailable() public view {
        // On Foundry test env, there's no code at the precompile address
        assertFalse(router.xcmPrecompileAvailable());
    }

    function test_refreshPrecompileStatus() public {
        // Deploy mock code at precompile address to simulate availability
        vm.etch(router.XCM_PRECOMPILE(), hex"00");
        router.refreshPrecompileStatus();
        assertTrue(router.xcmPrecompileAvailable());

        // Remove code
        vm.etch(router.XCM_PRECOMPILE(), hex"");
        router.refreshPrecompileStatus();
        assertFalse(router.xcmPrecompileAvailable());
    }

    function test_refreshPrecompileStatus_revertNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        router.refreshPrecompileStatus();
    }

    // =========================================================================
    // Pause Tests
    // =========================================================================

    function test_pause_success() public {
        router.pause();
        assertTrue(router.paused());
    }

    function test_unpause_success() public {
        router.pause();
        router.unpause();
        assertFalse(router.paused());
    }

    function test_pause_revertNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        router.pause();
    }

    function test_pause_blocksDispatches() public {
        router.pause();

        vm.prank(caller);
        vm.expectRevert();
        router.dispatchToParachain{value: 1 ether}(1, BIFROST_PARA_ID, 1 ether);
    }

    function test_pause_doesNotBlockConfirmations() public {
        _dispatch(1, BIFROST_PARA_ID, 1 ether);
        router.pause();

        // Relayer can still confirm even when paused (no whenNotPaused on confirm)
        vm.prank(relayer);
        router.confirmDispatch(1);
        assertTrue(router.getDispatch(1).status == XcmTypes.XcmStatus.Confirmed);
    }

    // =========================================================================
    // Receive Ether Tests
    // =========================================================================

    function test_receive_acceptsEther() public {
        (bool sent, ) = address(router).call{value: 1 ether}("");
        assertTrue(sent);
        assertEq(address(router).balance, 1 ether);
    }

    // =========================================================================
    // Full Dispatch Lifecycle Tests
    // =========================================================================

    function test_fullLifecycle_dispatchConfirmReturnConfirm() public {
        // 1. Dispatch
        uint256 dispatchId = _dispatch(1, BIFROST_PARA_ID, 10 ether);
        assertEq(router.pendingDispatches(), 1);
        assertEq(router.amountInTransit(), 10 ether);

        // 2. Confirm dispatch
        vm.prank(relayer);
        router.confirmDispatch(dispatchId);
        assertEq(router.pendingDispatches(), 0);
        assertEq(router.amountInTransit(), 0);

        // 3. Initiate return with yield
        vm.prank(relayer);
        router.initiateReturn(dispatchId, 1 ether);

        // 4. Confirm return with funds
        vm.deal(relayer, 11 ether);
        vm.prank(relayer);
        router.confirmReturn{value: 11 ether}(dispatchId);

        assertEq(address(router).balance, 21 ether); // 10 original + 11 returned
    }

    function test_fullLifecycle_dispatchFailed() public {
        uint256 dispatchId = _dispatch(1, BIFROST_PARA_ID, 5 ether);

        vm.prank(relayer);
        router.markDispatchFailed(dispatchId, "destination chain halted");

        XcmTypes.XcmDispatch memory d = router.getDispatch(dispatchId);
        assertTrue(d.status == XcmTypes.XcmStatus.Failed);
        assertEq(router.pendingDispatches(), 0);
        // Funds still in contract for recovery
        assertEq(address(router).balance, 5 ether);
    }

    function test_fullLifecycle_dispatchTimedOut() public {
        uint256 dispatchId = _dispatch(1, BIFROST_PARA_ID, 5 ether);

        // Fast forward past timeout
        vm.warp(block.timestamp + 6 hours);

        // Anyone can mark timed out
        vm.prank(alice);
        router.markTimedOut(dispatchId);

        XcmTypes.XcmDispatch memory d = router.getDispatch(dispatchId);
        assertTrue(d.status == XcmTypes.XcmStatus.TimedOut);
        assertEq(router.pendingDispatches(), 0);
    }

    // =========================================================================
    // XcmBuilder Library Tests
    // =========================================================================

    function test_xcmBuilder_parachain() public pure {
        bytes memory junction = XcmBuilder.parachain(2030);
        // First byte should be JUNCTION_PARACHAIN (0x00)
        assertEq(uint8(junction[0]), 0x00);
        // Next 4 bytes are little-endian 2030
        // 2030 = 0x07EE → LE = [0xEE, 0x07, 0x00, 0x00]
        assertEq(uint8(junction[1]), 0xEE);
        assertEq(uint8(junction[2]), 0x07);
        assertEq(uint8(junction[3]), 0x00);
        assertEq(uint8(junction[4]), 0x00);
        assertEq(junction.length, 5);
    }

    function test_xcmBuilder_accountKey20() public pure {
        address addr = 0x1234567890AbcdEF1234567890aBcdef12345678;
        bytes memory junction = XcmBuilder.accountKey20(addr);
        assertEq(uint8(junction[0]), 0x03); // JUNCTION_ACCOUNT_KEY_20
        assertEq(uint8(junction[1]), 0x00); // NETWORK_ANY
        assertEq(junction.length, 22); // 1 + 1 + 20
    }

    function test_xcmBuilder_accountId32() public pure {
        bytes32 id = keccak256("test-account");
        bytes memory junction = XcmBuilder.accountId32(id);
        assertEq(uint8(junction[0]), 0x01); // JUNCTION_ACCOUNT_ID_32
        assertEq(uint8(junction[1]), 0x00); // NETWORK_ANY
        assertEq(junction.length, 34); // 1 + 1 + 32
    }

    function test_xcmBuilder_buildParachainDest() public pure {
        (uint8 parents, bytes[] memory interior) = XcmBuilder.buildParachainDest(2030);
        assertEq(parents, 1); // Via relay chain
        assertEq(interior.length, 1);
        assertEq(uint8(interior[0][0]), 0x00); // Parachain junction
    }

    function test_xcmBuilder_buildEvmBeneficiary() public pure {
        address addr = address(0x1234567890AbcdEF1234567890aBcdef12345678);
        (uint8 parents, bytes[] memory interior) = XcmBuilder.buildEvmBeneficiary(addr);
        assertEq(parents, 0); // Local to destination
        assertEq(interior.length, 1);
        assertEq(uint8(interior[0][0]), 0x03); // AccountKey20 junction
    }

    function test_xcmBuilder_buildSubstrateBeneficiary() public pure {
        bytes32 id = keccak256("substrate-account");
        (uint8 parents, bytes[] memory interior) = XcmBuilder.buildSubstrateBeneficiary(id);
        assertEq(parents, 0);
        assertEq(interior.length, 1);
        assertEq(uint8(interior[0][0]), 0x01); // AccountId32 junction
    }

    function test_xcmBuilder_computeMessageHash_unique() public pure {
        bytes32 hash1 = XcmBuilder.computeMessageHash(1, 2030, 1 ether, bytes32(uint256(1)), 0);
        bytes32 hash2 = XcmBuilder.computeMessageHash(1, 2030, 1 ether, bytes32(uint256(1)), 1);
        bytes32 hash3 = XcmBuilder.computeMessageHash(2, 2030, 1 ether, bytes32(uint256(1)), 0);

        assertTrue(hash1 != hash2); // Different nonce
        assertTrue(hash1 != hash3); // Different routeId
        assertTrue(hash2 != hash3);
    }

    function test_xcmBuilder_computeMessageHash_deterministic() public pure {
        bytes32 hash1 = XcmBuilder.computeMessageHash(1, 2030, 1 ether, bytes32(uint256(1)), 0);
        bytes32 hash2 = XcmBuilder.computeMessageHash(1, 2030, 1 ether, bytes32(uint256(1)), 0);
        assertEq(hash1, hash2);
    }

    // =========================================================================
    // Edge Cases
    // =========================================================================

    function test_dispatch_afterTimeoutCanDispatchNewRoute() public {
        // Dispatch route 1
        _dispatch(1, BIFROST_PARA_ID, 1 ether);
        vm.warp(block.timestamp + 6 hours);
        router.markTimedOut(1);

        // Can still dispatch a different route
        uint256 id2 = _dispatch(2, BIFROST_PARA_ID, 2 ether);
        assertEq(id2, 2);
    }

    function test_dispatch_largeAmount() public {
        uint256 largeAmount = 1_000_000 ether;
        vm.deal(caller, largeAmount);

        vm.prank(caller);
        uint256 dispatchId = router.dispatchToParachain{value: largeAmount}(1, BIFROST_PARA_ID, largeAmount);
        assertEq(router.getDispatch(dispatchId).amount, largeAmount);
        assertEq(router.amountInTransit(), largeAmount);
    }

    function test_ownership_transfer() public {
        router.transferOwnership(alice);
        vm.prank(alice);
        router.acceptOwnership();
        assertEq(router.owner(), alice);

        // Old owner cannot admin
        vm.expectRevert();
        router.addRelayer(relayer2);
    }
}
