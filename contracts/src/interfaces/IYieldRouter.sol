// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IYieldRouter
/// @notice Interface for the cross-chain yield routing optimizer
/// @dev Uses XCM on Polkadot Hub to route funds to highest-yielding parachains
interface IYieldRouter {
    // =========================================================================
    // Enums
    // =========================================================================

    /// @notice Status of a yield route
    enum RouteStatus {
        Pending,    // XCM dispatch sent, awaiting confirmation
        Active,     // Funds deployed and earning yield
        Withdrawing,// Withdrawal initiated
        Completed,  // Funds returned to user
        Failed      // XCM dispatch failed
    }

    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice A supported yield source on a parachain
    /// @param paraId Polkadot parachain ID
    /// @param protocol Name of the yield protocol
    /// @param isActive Whether the route is currently accepting deposits
    /// @param currentApyBps Current APY in basis points (e.g. 500 = 5%)
    /// @param totalDeposited Total amount deposited into this source
    /// @param maxCapacity Maximum amount that can be deposited
    /// @param lastUpdated Timestamp of last APY update
    struct YieldSource {
        uint32 paraId;
        string protocol;
        bool isActive;
        uint256 currentApyBps;
        uint256 totalDeposited;
        uint256 maxCapacity;
        uint64 lastUpdated;
    }

    /// @notice A user's deposit route
    /// @param user Address of the depositor
    /// @param sourceId Which yield source the funds are in
    /// @param amount Amount deposited
    /// @param status Current route status
    /// @param depositTimestamp When the deposit was made
    /// @param estimatedYield Estimated yield accrued (updated on check)
    struct UserRoute {
        address user;
        uint256 sourceId;
        uint256 amount;
        RouteStatus status;
        uint64 depositTimestamp;
        uint256 estimatedYield;
    }

    // =========================================================================
    // Events
    // =========================================================================

    event YieldSourceAdded(uint256 indexed sourceId, uint32 paraId, string protocol);
    event YieldSourceUpdated(uint256 indexed sourceId, uint256 newApyBps, bool isActive);
    event YieldSourceRemoved(uint256 indexed sourceId);

    event DepositRouted(
        uint256 indexed routeId,
        address indexed user,
        uint256 indexed sourceId,
        uint256 amount,
        uint32 paraId
    );

    event WithdrawalInitiated(uint256 indexed routeId, address indexed user, uint256 amount);
    event WithdrawalCompleted(uint256 indexed routeId, address indexed user, uint256 amount, uint256 yieldEarned);
    event AutoRebalanced(uint256 indexed routeId, uint256 fromSourceId, uint256 toSourceId, uint256 amount);

    /// @notice W2: Multi-oracle events
    event OracleAdded(address indexed oracle);
    event OracleRemoved(address indexed oracle);

    /// @notice W4: Yield reserve tracking event
    event YieldReserveFunded(address indexed funder, uint256 amount, uint256 newTotal);

    /// @notice XCM Router integration event
    event XcmRouterUpdated(address indexed xcmRouter);

    /// @notice Legacy event kept for backward compatibility
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event MinDepositUpdated(uint256 oldMin, uint256 newMin);

    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidSourceId();
    error SourceNotActive();
    error SourceAtCapacity();
    error InvalidAmount();
    error BelowMinDeposit();
    error InvalidRouteId();
    error RouteNotActive();
    error OnlyRouteOwner();
    error OnlyOracle();
    error TransferFailed();
    error NativeTransferFailed();
    error NoActiveSource();
    error XCMDispatchFailed();
    error WithdrawalInProgress();

    /// @notice W2: Multi-oracle errors
    error OracleAlreadyAuthorized();
    error OracleNotAuthorized();
    error CannotRemoveLastOracle();

    /// @notice W4: Yield reserve insufficient for payout
    error InsufficientYieldReserve();

    // =========================================================================
    // Functions
    // =========================================================================

    /// @notice Deposit native token and auto-route to best yield
    /// @return routeId Unique identifier for this deposit route
    function depositAndRoute() external payable returns (uint256 routeId);

    /// @notice Deposit native token to a specific yield source
    /// @param sourceId The yield source to deposit into
    /// @return routeId Unique identifier for this deposit route
    function depositToSource(uint256 sourceId) external payable returns (uint256 routeId);

    /// @notice Initiate withdrawal from a yield route
    /// @param routeId The route to withdraw from
    function initiateWithdrawal(uint256 routeId) external;

    /// @notice Complete a pending withdrawal (called by oracle/XCM callback)
    /// @param routeId The route being withdrawn
    /// @param yieldEarned Actual yield earned from the source
    function completeWithdrawal(uint256 routeId, uint256 yieldEarned) external;

    /// @notice Get the best available yield source
    /// @return sourceId ID of the highest APY active source with capacity
    /// @return apyBps Current APY in basis points
    function getBestYieldSource() external view returns (uint256 sourceId, uint256 apyBps);

    /// @notice Get details about a yield source
    /// @param sourceId The source to query
    /// @return source Full yield source details
    function getYieldSource(uint256 sourceId) external view returns (YieldSource memory source);

    /// @notice Get a user's route details
    /// @param routeId The route to query
    /// @return route Full route details
    function getUserRoute(uint256 routeId) external view returns (UserRoute memory route);

    /// @notice Get all active route IDs for a user
    /// @param user The user address
    /// @return routeIds Array of active route IDs
    function getUserActiveRoutes(address user) external view returns (uint256[] memory routeIds);

    /// @notice Get total number of yield sources
    function getYieldSourceCount() external view returns (uint256);

    /// @notice Get total number of routes
    function getRouteCount() external view returns (uint256);
}
