// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {YieldRouter} from "../src/YieldRouter.sol";
import {IYieldRouter} from "../src/interfaces/IYieldRouter.sol";
import {TimelockAdmin} from "../src/TimelockAdmin.sol";

/// @title YieldRouterTest
/// @notice Comprehensive test suite for the Yield Router contract
contract YieldRouterTest is Test {
    YieldRouter public router;

    address public owner = address(this);
    address public oracle = makeAddr("oracle");
    address public oracle2 = makeAddr("oracle2");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public attacker = makeAddr("attacker");

    uint256 public constant MIN_DEPOSIT = 0.01 ether;

    event YieldSourceAdded(uint256 indexed sourceId, uint32 paraId, string protocol);
    event YieldSourceUpdated(uint256 indexed sourceId, uint256 newApyBps, bool isActive);
    event DepositRouted(
        uint256 indexed routeId,
        address indexed user,
        uint256 indexed sourceId,
        uint256 amount,
        uint32 paraId
    );
    event WithdrawalInitiated(uint256 indexed routeId, address indexed user, uint256 amount);
    event WithdrawalCompleted(uint256 indexed routeId, address indexed user, uint256 amount, uint256 yieldEarned);
    event OracleAdded(address indexed oracle);
    event OracleRemoved(address indexed oracle);
    event YieldReserveFunded(address indexed funder, uint256 amount, uint256 newTotal);
    event TimelockScheduled(bytes32 indexed opHash, uint64 readyAt);
    event TimelockExecuted(bytes32 indexed opHash);
    event MinDepositUpdated(uint256 oldMin, uint256 newMin);

    function setUp() public {
        router = new YieldRouter(oracle, MIN_DEPOSIT);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(attacker, 10 ether);

        _addDefaultSources();
    }

    function _addDefaultSources() internal {
        // Source 0: Bifrost — 12% APY, 1000 DOT cap
        router.addYieldSource(2030, "Bifrost vDOT", 1200, 1000 ether);
        // Source 1: HydraDX — 8.5% APY, 5000 DOT cap
        router.addYieldSource(2034, "HydraDX Omnipool", 850, 5000 ether);
        // Source 2: Acala — 9.5% APY, 2000 DOT cap
        router.addYieldSource(2000, "Acala LDOT", 950, 2000 ether);
    }

    // =========================================================================
    // Constructor Tests
    // =========================================================================

    function test_constructor_setsState() public view {
        assertTrue(router.isAuthorizedOracle(oracle));
        assertEq(router.oracleCount(), 1);
        assertEq(router.minDeposit(), MIN_DEPOSIT);
        assertEq(router.getYieldSourceCount(), 3);
        assertEq(router.getRouteCount(), 0);
        assertEq(router.totalValueLocked(), 0);
        assertEq(router.yieldReserve(), 0);
    }

    function test_constructor_revertZeroOracle() public {
        vm.expectRevert(IYieldRouter.OnlyOracle.selector);
        new YieldRouter(address(0), MIN_DEPOSIT);
    }

    // =========================================================================
    // [W2] Multi-Oracle Tests
    // =========================================================================

    function test_addOracle_success() public {
        vm.expectEmit(true, true, true, true);
        emit OracleAdded(oracle2);

        router.addOracle(oracle2);
        assertTrue(router.isAuthorizedOracle(oracle2));
        assertEq(router.oracleCount(), 2);
    }

    function test_addOracle_revertAlreadyAuthorized() public {
        vm.expectRevert(IYieldRouter.OracleAlreadyAuthorized.selector);
        router.addOracle(oracle); // Already added in constructor
    }

    function test_addOracle_revertZeroAddress() public {
        vm.expectRevert(IYieldRouter.OnlyOracle.selector);
        router.addOracle(address(0));
    }

    function test_addOracle_revertNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        router.addOracle(oracle2);
    }

    function test_removeOracle_success() public {
        // Add a second oracle first
        router.addOracle(oracle2);
        assertEq(router.oracleCount(), 2);

        vm.expectEmit(true, true, true, true);
        emit OracleRemoved(oracle);

        router.removeOracle(oracle);
        assertFalse(router.isAuthorizedOracle(oracle));
        assertEq(router.oracleCount(), 1);
    }

    function test_removeOracle_revertLastOracle() public {
        // Only 1 oracle — cannot remove
        vm.expectRevert(IYieldRouter.CannotRemoveLastOracle.selector);
        router.removeOracle(oracle);
    }

    function test_removeOracle_revertNotAuthorized() public {
        vm.expectRevert(IYieldRouter.OracleNotAuthorized.selector);
        router.removeOracle(makeAddr("nobody"));
    }

    function test_multiOracle_bothCanOperate() public {
        router.addOracle(oracle2);

        // Both oracles can update yield rates
        vm.prank(oracle);
        router.updateYieldRate(0, 1300);

        vm.prank(oracle2);
        router.updateYieldRate(0, 1400);

        IYieldRouter.YieldSource memory s = router.getYieldSource(0);
        assertEq(s.currentApyBps, 1400);
    }

    function test_removedOracle_cannotOperate() public {
        router.addOracle(oracle2);
        router.removeOracle(oracle);

        vm.prank(oracle);
        vm.expectRevert(IYieldRouter.OnlyOracle.selector);
        router.updateYieldRate(0, 1500);

        // oracle2 still works
        vm.prank(oracle2);
        router.updateYieldRate(0, 1500);
    }

    // =========================================================================
    // Yield Source Management Tests
    // =========================================================================

    function test_addYieldSource() public {
        uint256 sourceId = router.addYieldSource(3000, "TestChain", 500, 100 ether);
        assertEq(sourceId, 3);

        IYieldRouter.YieldSource memory s = router.getYieldSource(sourceId);
        assertEq(s.paraId, 3000);
        assertEq(s.currentApyBps, 500);
        assertTrue(s.isActive);
        assertEq(s.maxCapacity, 100 ether);
    }

    function test_addYieldSource_revertNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        router.addYieldSource(3000, "TestChain", 500, 100 ether);
    }

    function test_addYieldSource_revertApyTooHigh() public {
        vm.expectRevert(IYieldRouter.InvalidAmount.selector);
        router.addYieldSource(3000, "TestChain", 10001, 100 ether);
    }

    function test_addYieldSource_revertZeroCapacity() public {
        vm.expectRevert(IYieldRouter.InvalidAmount.selector);
        router.addYieldSource(3000, "TestChain", 500, 0);
    }

    function test_setSourceActive() public {
        router.setSourceActive(0, false);
        IYieldRouter.YieldSource memory s = router.getYieldSource(0);
        assertFalse(s.isActive);

        router.setSourceActive(0, true);
        s = router.getYieldSource(0);
        assertTrue(s.isActive);
    }

    // =========================================================================
    // getBestYieldSource Tests
    // =========================================================================

    function test_getBestYieldSource() public view {
        (uint256 sourceId, uint256 apyBps) = router.getBestYieldSource();
        assertEq(sourceId, 0); // Bifrost at 12%
        assertEq(apyBps, 1200);
    }

    function test_getBestYieldSource_afterDisabling() public {
        router.setSourceActive(0, false);

        (uint256 sourceId, uint256 apyBps) = router.getBestYieldSource();
        assertEq(sourceId, 2); // Acala at 9.5%
        assertEq(apyBps, 950);
    }

    function test_getBestYieldSource_afterApyUpdate() public {
        vm.prank(oracle);
        router.updateYieldRate(1, 1500); // HydraDX to 15%

        (uint256 sourceId, uint256 apyBps) = router.getBestYieldSource();
        assertEq(sourceId, 1);
        assertEq(apyBps, 1500);
    }

    // =========================================================================
    // depositAndRoute Tests
    // =========================================================================

    function test_depositAndRoute_success() public {
        vm.prank(alice);
        uint256 routeId = router.depositAndRoute{value: 1 ether}();

        assertEq(routeId, 0);
        assertEq(router.getRouteCount(), 1);
        assertEq(router.totalValueLocked(), 1 ether);

        IYieldRouter.UserRoute memory r = router.getUserRoute(routeId);
        assertEq(r.user, alice);
        assertEq(r.sourceId, 0);
        assertEq(r.amount, 1 ether);
        assertEq(uint8(r.status), uint8(IYieldRouter.RouteStatus.Active));
    }

    function test_depositAndRoute_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit DepositRouted(0, alice, 0, 1 ether, 2030);

        vm.prank(alice);
        router.depositAndRoute{value: 1 ether}();
    }

    function test_depositAndRoute_revertBelowMinDeposit() public {
        vm.prank(alice);
        vm.expectRevert(IYieldRouter.BelowMinDeposit.selector);
        router.depositAndRoute{value: 0.001 ether}();
    }

    function test_depositAndRoute_revertWhenPaused() public {
        router.pause();

        vm.prank(alice);
        vm.expectRevert();
        router.depositAndRoute{value: 1 ether}();
    }

    function test_depositAndRoute_updatesSourceTotalDeposited() public {
        vm.prank(alice);
        router.depositAndRoute{value: 10 ether}();

        IYieldRouter.YieldSource memory s = router.getYieldSource(0);
        assertEq(s.totalDeposited, 10 ether);
    }

    // =========================================================================
    // depositToSource Tests
    // =========================================================================

    function test_depositToSource_success() public {
        vm.prank(alice);
        uint256 routeId = router.depositToSource{value: 5 ether}(1);

        IYieldRouter.UserRoute memory r = router.getUserRoute(routeId);
        assertEq(r.sourceId, 1);
        assertEq(r.amount, 5 ether);
    }

    function test_depositToSource_revertInvalidSource() public {
        vm.prank(alice);
        vm.expectRevert(IYieldRouter.InvalidSourceId.selector);
        router.depositToSource{value: 1 ether}(99);
    }

    function test_depositToSource_revertInactiveSource() public {
        router.setSourceActive(1, false);

        vm.prank(alice);
        vm.expectRevert(IYieldRouter.SourceNotActive.selector);
        router.depositToSource{value: 1 ether}(1);
    }

    function test_depositToSource_revertAtCapacity() public {
        vm.deal(alice, 2000 ether);
        vm.prank(alice);
        router.depositToSource{value: 999 ether}(0);

        vm.prank(alice);
        vm.expectRevert(IYieldRouter.SourceAtCapacity.selector);
        router.depositToSource{value: 2 ether}(0);
    }

    // =========================================================================
    // Withdrawal Tests
    // =========================================================================

    function test_initiateWithdrawal_success() public {
        vm.prank(alice);
        uint256 routeId = router.depositAndRoute{value: 1 ether}();

        vm.expectEmit(true, true, true, true);
        emit WithdrawalInitiated(routeId, alice, 1 ether);

        vm.prank(alice);
        router.initiateWithdrawal(routeId);

        IYieldRouter.UserRoute memory r = router.getUserRoute(routeId);
        assertEq(uint8(r.status), uint8(IYieldRouter.RouteStatus.Withdrawing));
    }

    function test_initiateWithdrawal_revertNotOwner() public {
        vm.prank(alice);
        uint256 routeId = router.depositAndRoute{value: 1 ether}();

        vm.prank(attacker);
        vm.expectRevert(IYieldRouter.OnlyRouteOwner.selector);
        router.initiateWithdrawal(routeId);
    }

    function test_initiateWithdrawal_revertNotActive() public {
        vm.prank(alice);
        uint256 routeId = router.depositAndRoute{value: 1 ether}();

        vm.prank(alice);
        router.initiateWithdrawal(routeId);

        vm.prank(alice);
        vm.expectRevert(IYieldRouter.RouteNotActive.selector);
        router.initiateWithdrawal(routeId);
    }

    function test_completeWithdrawal_success() public {
        vm.prank(alice);
        uint256 routeId = router.depositAndRoute{value: 1 ether}();

        vm.prank(alice);
        router.initiateWithdrawal(routeId);

        // [W4] Fund the yield reserve
        uint256 yieldAmount = 0.1 ether;
        vm.deal(oracle, yieldAmount);
        vm.prank(oracle);
        router.fundYieldReserve{value: yieldAmount}();

        uint256 aliceBalBefore = alice.balance;

        vm.prank(oracle);
        router.completeWithdrawal(routeId, yieldAmount);

        assertEq(alice.balance, aliceBalBefore + 1 ether + yieldAmount);
        assertEq(router.totalValueLocked(), 0);
        assertEq(router.yieldReserve(), 0); // [W4] Reserve fully consumed

        IYieldRouter.UserRoute memory r = router.getUserRoute(routeId);
        assertEq(uint8(r.status), uint8(IYieldRouter.RouteStatus.Completed));
        assertEq(r.estimatedYield, yieldAmount);
    }

    function test_completeWithdrawal_revertNotOracle() public {
        vm.prank(alice);
        uint256 routeId = router.depositAndRoute{value: 1 ether}();

        vm.prank(alice);
        router.initiateWithdrawal(routeId);

        vm.prank(attacker);
        vm.expectRevert(IYieldRouter.OnlyOracle.selector);
        router.completeWithdrawal(routeId, 0);
    }

    // =========================================================================
    // [W4] Yield Reserve Tests
    // =========================================================================

    function test_fundYieldReserve_tracksReserve() public {
        vm.deal(oracle, 5 ether);

        vm.expectEmit(true, true, true, true);
        emit YieldReserveFunded(oracle, 2 ether, 2 ether);

        vm.prank(oracle);
        router.fundYieldReserve{value: 2 ether}();
        assertEq(router.yieldReserve(), 2 ether);

        vm.expectEmit(true, true, true, true);
        emit YieldReserveFunded(oracle, 1 ether, 3 ether);

        vm.prank(oracle);
        router.fundYieldReserve{value: 1 ether}();
        assertEq(router.yieldReserve(), 3 ether);
    }

    function test_completeWithdrawal_revertInsufficientReserve() public {
        vm.prank(alice);
        uint256 routeId = router.depositAndRoute{value: 1 ether}();

        vm.prank(alice);
        router.initiateWithdrawal(routeId);

        // Fund less yield than claimed
        vm.deal(oracle, 0.05 ether);
        vm.prank(oracle);
        router.fundYieldReserve{value: 0.05 ether}();

        // Try to claim 0.1 ETH yield — should fail
        vm.prank(oracle);
        vm.expectRevert(IYieldRouter.InsufficientYieldReserve.selector);
        router.completeWithdrawal(routeId, 0.1 ether);
    }

    function test_completeWithdrawal_zeroYieldSucceeds() public {
        vm.prank(alice);
        uint256 routeId = router.depositAndRoute{value: 1 ether}();

        vm.prank(alice);
        router.initiateWithdrawal(routeId);

        // No yield reserve needed for 0 yield
        uint256 aliceBefore = alice.balance;
        vm.prank(oracle);
        router.completeWithdrawal(routeId, 0);

        assertEq(alice.balance, aliceBefore + 1 ether);
    }

    function test_yieldReserve_deductedOnComplete() public {
        vm.prank(alice);
        uint256 routeId = router.depositAndRoute{value: 1 ether}();

        vm.prank(alice);
        router.initiateWithdrawal(routeId);

        // Fund 1 ETH reserve, claim 0.3 yield
        vm.deal(oracle, 1 ether);
        vm.prank(oracle);
        router.fundYieldReserve{value: 1 ether}();
        assertEq(router.yieldReserve(), 1 ether);

        vm.prank(oracle);
        router.completeWithdrawal(routeId, 0.3 ether);

        assertEq(router.yieldReserve(), 0.7 ether);
    }

    // =========================================================================
    // markRouteFailed Tests
    // =========================================================================

    function test_markRouteFailed_refundsUser() public {
        vm.prank(alice);
        uint256 routeId = router.depositAndRoute{value: 2 ether}();

        uint256 aliceBalBefore = alice.balance;

        vm.prank(oracle);
        router.markRouteFailed(routeId);

        assertEq(alice.balance, aliceBalBefore + 2 ether);

        IYieldRouter.UserRoute memory r = router.getUserRoute(routeId);
        assertEq(uint8(r.status), uint8(IYieldRouter.RouteStatus.Failed));
    }

    function test_markRouteFailed_doesNotTouchReserve() public {
        // Fund reserve first
        vm.deal(oracle, 1 ether);
        vm.prank(oracle);
        router.fundYieldReserve{value: 1 ether}();

        vm.prank(alice);
        uint256 routeId = router.depositAndRoute{value: 2 ether}();

        vm.prank(oracle);
        router.markRouteFailed(routeId);

        // Reserve should be unchanged
        assertEq(router.yieldReserve(), 1 ether);
    }

    function test_markRouteFailed_revertNotOracle() public {
        vm.prank(alice);
        uint256 routeId = router.depositAndRoute{value: 1 ether}();

        vm.prank(attacker);
        vm.expectRevert(IYieldRouter.OnlyOracle.selector);
        router.markRouteFailed(routeId);
    }

    // =========================================================================
    // [W5] Pagination Tests
    // =========================================================================

    function test_getUserRoutesPaginated() public {
        vm.startPrank(alice);
        for (uint256 i = 0; i < 5; i++) {
            router.depositAndRoute{value: 1 ether}();
        }
        vm.stopPrank();

        // Page 1
        (uint256[] memory page1, uint256 total) = router.getUserRoutesPaginated(alice, 0, 2);
        assertEq(total, 5);
        assertEq(page1.length, 2);
        assertEq(page1[0], 0);
        assertEq(page1[1], 1);

        // Page 3 (partial)
        (uint256[] memory page3, ) = router.getUserRoutesPaginated(alice, 4, 2);
        assertEq(page3.length, 1);
        assertEq(page3[0], 4);

        // Out of bounds
        (uint256[] memory empty, uint256 total2) = router.getUserRoutesPaginated(alice, 10, 2);
        assertEq(total2, 5);
        assertEq(empty.length, 0);
    }

    function test_getUserActiveRoutesPaginated() public {
        vm.startPrank(alice);
        router.depositAndRoute{value: 1 ether}(); // 0 active
        router.depositAndRoute{value: 1 ether}(); // 1 active
        router.depositAndRoute{value: 1 ether}(); // 2 active
        router.depositAndRoute{value: 1 ether}(); // 3 active
        vm.stopPrank();

        // Withdraw route 1
        vm.prank(alice);
        router.initiateWithdrawal(1);

        // 3 active routes remain: [0, 2, 3]
        (uint256[] memory page, uint256 totalActive) = router.getUserActiveRoutesPaginated(alice, 0, 2);
        assertEq(totalActive, 3);
        assertEq(page.length, 2);
        assertEq(page[0], 0);
        assertEq(page[1], 2);

        // Second page
        (uint256[] memory page2, ) = router.getUserActiveRoutesPaginated(alice, 2, 2);
        assertEq(page2.length, 1);
        assertEq(page2[0], 3);
    }

    // =========================================================================
    // User Routes View Tests
    // =========================================================================

    function test_getUserActiveRoutes() public {
        vm.startPrank(alice);
        uint256 id0 = router.depositAndRoute{value: 1 ether}();
        uint256 id1 = router.depositAndRoute{value: 2 ether}();
        uint256 id2 = router.depositAndRoute{value: 3 ether}();
        vm.stopPrank();

        vm.prank(alice);
        router.initiateWithdrawal(id1);

        uint256[] memory activeRoutes = router.getUserActiveRoutes(alice);
        assertEq(activeRoutes.length, 2);
        assertEq(activeRoutes[0], id0);
        assertEq(activeRoutes[1], id2);
    }

    function test_getUserRouteIds() public {
        vm.startPrank(alice);
        router.depositAndRoute{value: 1 ether}();
        router.depositAndRoute{value: 2 ether}();
        vm.stopPrank();

        uint256[] memory allRoutes = router.getUserRouteIds(alice);
        assertEq(allRoutes.length, 2);
    }

    // =========================================================================
    // Oracle Rate Update Tests
    // =========================================================================

    function test_updateYieldRate_success() public {
        vm.prank(oracle);
        router.updateYieldRate(0, 1500);

        IYieldRouter.YieldSource memory s = router.getYieldSource(0);
        assertEq(s.currentApyBps, 1500);
    }

    function test_updateYieldRate_revertNotOracle() public {
        vm.prank(attacker);
        vm.expectRevert(IYieldRouter.OnlyOracle.selector);
        router.updateYieldRate(0, 1500);
    }

    function test_updateYieldRate_revertInvalidSource() public {
        vm.prank(oracle);
        vm.expectRevert(IYieldRouter.InvalidSourceId.selector);
        router.updateYieldRate(99, 500);
    }

    function test_updateYieldRate_revertApyTooHigh() public {
        vm.prank(oracle);
        vm.expectRevert(IYieldRouter.InvalidAmount.selector);
        router.updateYieldRate(0, 10001);
    }

    // =========================================================================
    // [W3] Timelock Tests — Min Deposit
    // =========================================================================

    function test_scheduleMinDepositChange_success() public {
        uint256 newMin = 1 ether;
        bytes32 opHash = keccak256(abi.encode("setMinDeposit", newMin));

        vm.expectEmit(true, true, true, true);
        emit TimelockScheduled(opHash, uint64(block.timestamp) + 2 hours);

        router.scheduleMinDepositChange(newMin);
        assertGt(router.timelockReady(opHash), 0);
    }

    function test_executeMinDepositChange_success() public {
        uint256 newMin = 1 ether;
        router.scheduleMinDepositChange(newMin);
        vm.warp(block.timestamp + 2 hours + 1);

        vm.expectEmit(true, true, true, true);
        emit MinDepositUpdated(MIN_DEPOSIT, newMin);

        router.executeMinDepositChange(newMin);
        assertEq(router.minDeposit(), newMin);
    }

    function test_executeMinDepositChange_revertTooEarly() public {
        router.scheduleMinDepositChange(1 ether);
        vm.warp(block.timestamp + 1 hours);

        vm.expectRevert(TimelockAdmin.TimelockNotReady.selector);
        router.executeMinDepositChange(1 ether);
    }

    function test_executeMinDepositChange_revertNotScheduled() public {
        vm.expectRevert(TimelockAdmin.TimelockNotScheduled.selector);
        router.executeMinDepositChange(1 ether);
    }

    function test_cancelTimelock_success() public {
        uint256 newMin = 1 ether;
        bytes32 opHash = keccak256(abi.encode("setMinDeposit", newMin));

        router.scheduleMinDepositChange(newMin);
        assertGt(router.timelockReady(opHash), 0);

        router.cancelTimelock(opHash);
        assertEq(router.timelockReady(opHash), 0);
    }

    function test_cancelTimelock_revertNotOwner() public {
        router.scheduleMinDepositChange(1 ether);
        bytes32 opHash = keccak256(abi.encode("setMinDeposit", uint256(1 ether)));

        vm.prank(attacker);
        vm.expectRevert();
        router.cancelTimelock(opHash);
    }

    // =========================================================================
    // Admin Tests
    // =========================================================================

    function test_pauseUnpause() public {
        router.pause();
        assertTrue(router.paused());

        router.unpause();
        assertFalse(router.paused());
    }

    // =========================================================================
    // Receive Test
    // =========================================================================

    function test_receive_revertDirectTransfer() public {
        vm.prank(alice);
        vm.expectRevert("Use deposit functions");
        (bool success,) = address(router).call{value: 1 ether}("");
        success;
    }

    // =========================================================================
    // Fuzz Tests
    // =========================================================================

    function testFuzz_depositAndRoute_variousAmounts(uint256 amount) public {
        amount = bound(amount, MIN_DEPOSIT, 999 ether);
        vm.deal(alice, amount);

        vm.prank(alice);
        uint256 routeId = router.depositAndRoute{value: amount}();

        IYieldRouter.UserRoute memory r = router.getUserRoute(routeId);
        assertEq(r.amount, amount);
        assertEq(router.totalValueLocked(), amount);
    }

    function testFuzz_fullCycle_noValueLeak(uint256 amount, uint256 yield_) public {
        amount = bound(amount, MIN_DEPOSIT, 100 ether);
        yield_ = bound(yield_, 0, 10 ether);
        vm.deal(alice, amount);

        vm.prank(alice);
        uint256 routeId = router.depositAndRoute{value: amount}();

        vm.prank(alice);
        router.initiateWithdrawal(routeId);

        // [W4] Fund yield reserve properly
        vm.deal(oracle, yield_);
        vm.prank(oracle);
        router.fundYieldReserve{value: yield_}();

        uint256 aliceBefore = alice.balance;

        vm.prank(oracle);
        router.completeWithdrawal(routeId, yield_);

        assertEq(alice.balance, aliceBefore + amount + yield_);
        assertEq(router.yieldReserve(), 0); // All yield consumed
    }

    function testFuzz_W4_cannotClaimMoreThanReserve(uint256 amount, uint256 funded, uint256 claimed) public {
        amount = bound(amount, MIN_DEPOSIT, 100 ether);
        funded = bound(funded, 0, 10 ether);
        claimed = bound(claimed, funded + 1, funded + 100 ether); // Always more than funded
        vm.deal(alice, amount);

        vm.prank(alice);
        uint256 routeId = router.depositAndRoute{value: amount}();

        vm.prank(alice);
        router.initiateWithdrawal(routeId);

        if (funded > 0) {
            vm.deal(oracle, funded);
            vm.prank(oracle);
            router.fundYieldReserve{value: funded}();
        }

        vm.prank(oracle);
        vm.expectRevert(IYieldRouter.InsufficientYieldReserve.selector);
        router.completeWithdrawal(routeId, claimed);
    }
}
