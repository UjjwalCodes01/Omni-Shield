// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title TimelockAdmin
/// @author Omni-Shield Team
/// @notice Abstract base providing inline timelock for sensitive admin operations
/// @dev Inherit this in any contract that needs timelocked parameter changes.
///      Owner schedules a change → waits TIMELOCK_DELAY → anyone can execute.
///      Owner can cancel any pending change before execution.
abstract contract TimelockAdmin {
    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Delay before a scheduled change can be executed (2 hours — testnet-friendly)
    uint64 public constant TIMELOCK_DELAY = 2 hours;

    // =========================================================================
    // State
    // =========================================================================

    /// @notice Pending timelock operations: opHash => readyTimestamp (0 = not scheduled)
    mapping(bytes32 opHash => uint64 readyAt) public timelockReady;

    // =========================================================================
    // Events
    // =========================================================================

    event TimelockScheduled(bytes32 indexed opHash, uint64 readyAt);
    event TimelockExecuted(bytes32 indexed opHash);
    event TimelockCancelled(bytes32 indexed opHash);

    // =========================================================================
    // Errors
    // =========================================================================

    error TimelockNotReady();
    error TimelockNotScheduled();
    error TimelockAlreadyScheduled();

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// @notice Schedule a timelock operation
    /// @param opHash Unique hash identifying the operation and its parameters
    function _scheduleTimelock(bytes32 opHash) internal {
        if (timelockReady[opHash] != 0) revert TimelockAlreadyScheduled();
        uint64 readyAt = uint64(block.timestamp) + TIMELOCK_DELAY;
        timelockReady[opHash] = readyAt;
        emit TimelockScheduled(opHash, readyAt);
    }

    /// @notice Execute a timelock operation (reverts if not ready)
    /// @param opHash Unique hash of the operation being executed
    function _executeTimelock(bytes32 opHash) internal {
        uint64 readyAt = timelockReady[opHash];
        if (readyAt == 0) revert TimelockNotScheduled();
        if (uint64(block.timestamp) < readyAt) revert TimelockNotReady();
        delete timelockReady[opHash];
        emit TimelockExecuted(opHash);
    }

    /// @notice Cancel a pending timelock operation
    /// @param opHash Unique hash of the operation to cancel
    function _cancelTimelock(bytes32 opHash) internal {
        if (timelockReady[opHash] == 0) revert TimelockNotScheduled();
        delete timelockReady[opHash];
        emit TimelockCancelled(opHash);
    }
}
