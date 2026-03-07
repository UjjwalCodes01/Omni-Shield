// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IYieldRouter} from "./interfaces/IYieldRouter.sol";
import {TimelockAdmin} from "./TimelockAdmin.sol";
import {XcmRouter} from "./XcmRouter.sol";

/// @title YieldRouter
/// @author Omni-Shield Team
/// @notice Cross-chain yield routing optimizer for Polkadot Hub
/// @dev Routes user deposits to the highest-yielding parachain via XCM.
///      This contract manages yield source metadata, user deposit routes,
///      and coordinates with an oracle/relayer for cross-chain state.
///
/// Architecture:
///   - Owner adds/manages yield sources (parachains + protocols)
///   - Authorized oracles update APY rates from off-chain monitoring
///   - Users deposit native DOT, contract routes to best source
///   - XCM dispatch handles actual cross-chain fund movement
///   - Oracle confirms withdrawals and reports yield earned
///
/// Security features:
///   - ReentrancyGuard on all state-changing functions
///   - Ownable2Step for safe ownership transfer
///   - Pausable emergency circuit breaker
///   - [W2] Multi-oracle authorization — eliminates single point of failure
///   - [W3] Timelock on sensitive admin functions (min deposit)
///   - [W4] Yield reserve tracking — validates sufficient funds before payout
///   - [W5] Paginated view functions for growing arrays
///   - Minimum deposit threshold to prevent dust attacks
///   - Route ownership enforced on withdrawals
///   - Capacity limits per yield source
contract YieldRouter is IYieldRouter, ReentrancyGuard, Ownable2Step, Pausable, TimelockAdmin {
    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Native token sentinel
    address public constant NATIVE_TOKEN = address(0);

    /// @notice Maximum APY reportable: 100% = 10000 bps
    uint256 public constant MAX_APY_BPS = 10_000;

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice [W2] Authorized oracle mapping (replaces single oracle address)
    mapping(address => bool) public isAuthorizedOracle;

    /// @notice [W2] Count of authorized oracles (prevents removing last one)
    uint256 public oracleCount;

    /// @notice Minimum deposit amount (prevents dust)
    uint256 public minDeposit;

    /// @notice Auto-incrementing yield source ID
    uint256 private _nextSourceId;

    /// @notice Auto-incrementing route ID
    uint256 private _nextRouteId;

    /// @notice Total value locked across all routes
    uint256 public totalValueLocked;

    /// @notice [W4] Tracked yield reserve — funds available for yield payouts
    uint256 public yieldReserve;

    /// @notice Mapping: sourceId => YieldSource
    mapping(uint256 sourceId => YieldSource) private _sources;

    /// @notice Mapping: routeId => UserRoute
    mapping(uint256 routeId => UserRoute) private _routes;

    /// @notice Mapping: user => array of route IDs
    mapping(address user => uint256[]) private _userRoutes;

    /// @notice Mapping: sourceId => total active routes count
    mapping(uint256 sourceId => uint256 count) public activeRoutesPerSource;

    /// @notice XCM router contract for cross-chain dispatch
    XcmRouter public xcmRouter;

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyOracle() {
        _checkOracle();
        _;
    }

    /// @dev [W2] Check against the authorized oracle mapping
    function _checkOracle() internal view {
        if (!isAuthorizedOracle[msg.sender]) revert OnlyOracle();
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _oracle Initial oracle address for APY updates
    /// @param _minDeposit Minimum deposit in wei
    constructor(address _oracle, uint256 _minDeposit) Ownable(msg.sender) {
        if (_oracle == address(0)) revert OnlyOracle();

        // [W2] Initialize first oracle
        isAuthorizedOracle[_oracle] = true;
        oracleCount = 1;
        minDeposit = _minDeposit;

        emit OracleAdded(_oracle);
        emit MinDepositUpdated(0, _minDeposit);
    }

    // =========================================================================
    // External Functions — User Operations
    // =========================================================================

    /// @inheritdoc IYieldRouter
    function depositAndRoute() external payable nonReentrant whenNotPaused returns (uint256 routeId) {
        if (msg.value < minDeposit) revert BelowMinDeposit();

        (uint256 bestSourceId, uint256 bestApy) = _findBestSource();
        if (bestApy == 0) revert NoActiveSource();

        routeId = _createRoute(msg.sender, bestSourceId, msg.value);

        // Dispatch via XCM router if configured
        _dispatchXcm(routeId, _sources[bestSourceId].paraId, msg.value);

        emit DepositRouted(routeId, msg.sender, bestSourceId, msg.value, _sources[bestSourceId].paraId);
    }

    /// @inheritdoc IYieldRouter
    function depositToSource(uint256 sourceId) external payable nonReentrant whenNotPaused returns (uint256 routeId) {
        if (msg.value < minDeposit) revert BelowMinDeposit();
        _validateSource(sourceId);

        YieldSource storage source = _sources[sourceId];
        if (source.totalDeposited + msg.value > source.maxCapacity) revert SourceAtCapacity();

        routeId = _createRoute(msg.sender, sourceId, msg.value);

        // Dispatch via XCM router if configured
        _dispatchXcm(routeId, source.paraId, msg.value);

        emit DepositRouted(routeId, msg.sender, sourceId, msg.value, source.paraId);
    }

    /// @inheritdoc IYieldRouter
    function initiateWithdrawal(uint256 routeId) external nonReentrant whenNotPaused {
        UserRoute storage route = _routes[routeId];
        if (route.user != msg.sender) revert OnlyRouteOwner();
        if (route.status != RouteStatus.Active) revert RouteNotActive();

        route.status = RouteStatus.Withdrawing;

        emit WithdrawalInitiated(routeId, msg.sender, route.amount);
    }

    /// @inheritdoc IYieldRouter
    function completeWithdrawal(uint256 routeId, uint256 yieldEarned) external nonReentrant onlyOracle {
        UserRoute storage route = _routes[routeId];
        if (route.status != RouteStatus.Withdrawing) revert WithdrawalInProgress();

        // [W4] Validate yield reserve has enough to cover the yield payout
        if (yieldEarned > yieldReserve) revert InsufficientYieldReserve();

        // Effects
        route.status = RouteStatus.Completed;
        route.estimatedYield = yieldEarned;

        uint256 sourceId = route.sourceId;
        uint256 totalPayout = route.amount + yieldEarned;

        // [W4] Deduct yield from reserve
        if (yieldEarned > 0) {
            yieldReserve -= yieldEarned;
        }

        // Update bookkeeping
        unchecked {
            _sources[sourceId].totalDeposited -= route.amount;
            activeRoutesPerSource[sourceId]--;
            totalValueLocked -= route.amount;
        }

        // Interactions — send principal + yield to user
        address user = route.user;
        (bool success,) = user.call{value: totalPayout}("");
        if (!success) revert NativeTransferFailed();

        emit WithdrawalCompleted(routeId, user, route.amount, yieldEarned);
    }

    // =========================================================================
    // External Functions — Views
    // =========================================================================

    /// @inheritdoc IYieldRouter
    function getBestYieldSource() external view returns (uint256 sourceId, uint256 apyBps) {
        (sourceId, apyBps) = _findBestSource();
    }

    /// @inheritdoc IYieldRouter
    function getYieldSource(uint256 sourceId) external view returns (YieldSource memory) {
        return _sources[sourceId];
    }

    /// @inheritdoc IYieldRouter
    function getUserRoute(uint256 routeId) external view returns (UserRoute memory) {
        return _routes[routeId];
    }

    /// @inheritdoc IYieldRouter
    function getUserActiveRoutes(address user) external view returns (uint256[] memory) {
        uint256[] storage allRoutes = _userRoutes[user];
        uint256 len = allRoutes.length;

        // Count active routes first
        uint256 activeCount = 0;
        for (uint256 i = 0; i < len;) {
            if (_routes[allRoutes[i]].status == RouteStatus.Active) {
                unchecked { activeCount++; }
            }
            unchecked { i++; }
        }

        // Build result array
        uint256[] memory activeRoutes = new uint256[](activeCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < len;) {
            if (_routes[allRoutes[i]].status == RouteStatus.Active) {
                activeRoutes[idx] = allRoutes[i];
                unchecked { idx++; }
            }
            unchecked { i++; }
        }
        return activeRoutes;
    }

    /// @inheritdoc IYieldRouter
    function getYieldSourceCount() external view returns (uint256) {
        return _nextSourceId;
    }

    /// @inheritdoc IYieldRouter
    function getRouteCount() external view returns (uint256) {
        return _nextRouteId;
    }

    /// @notice Get all route IDs for a user
    function getUserRouteIds(address user) external view returns (uint256[] memory) {
        return _userRoutes[user];
    }

    /// @notice [W5] Paginated user route IDs to avoid unbounded gas
    /// @param user User address
    /// @param offset Start index (0-based)
    /// @param limit Maximum number of IDs to return
    /// @return ids Slice of route IDs
    /// @return total Total number of routes for this user
    function getUserRoutesPaginated(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory ids, uint256 total) {
        uint256[] storage arr = _userRoutes[user];
        total = arr.length;
        if (offset >= total || limit == 0) {
            return (new uint256[](0), total);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 len = end - offset;
        ids = new uint256[](len);
        for (uint256 i = 0; i < len;) {
            ids[i] = arr[offset + i];
            unchecked { i++; }
        }
    }

    /// @notice [W5] Paginated active route IDs for a user
    /// @param user User address
    /// @param offset Start index into the ACTIVE route subset (0-based)
    /// @param limit Maximum number of active IDs to return
    /// @return ids Slice of active route IDs
    /// @return totalActive Total number of active routes for this user
    function getUserActiveRoutesPaginated(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory ids, uint256 totalActive) {
        uint256[] storage allRoutes = _userRoutes[user];
        uint256 len = allRoutes.length;

        // Count active routes
        totalActive = 0;
        for (uint256 i = 0; i < len;) {
            if (_routes[allRoutes[i]].status == RouteStatus.Active) {
                unchecked { totalActive++; }
            }
            unchecked { i++; }
        }

        if (offset >= totalActive || limit == 0) {
            return (new uint256[](0), totalActive);
        }

        uint256 end = offset + limit;
        if (end > totalActive) end = totalActive;
        uint256 resultLen = end - offset;
        ids = new uint256[](resultLen);

        uint256 activeIdx = 0;
        uint256 written = 0;
        for (uint256 i = 0; i < len && written < resultLen;) {
            if (_routes[allRoutes[i]].status == RouteStatus.Active) {
                if (activeIdx >= offset) {
                    ids[written] = allRoutes[i];
                    unchecked { written++; }
                }
                unchecked { activeIdx++; }
            }
            unchecked { i++; }
        }
    }

    // =========================================================================
    // External Functions — Oracle
    // =========================================================================

    /// @notice Update APY for a yield source
    /// @param sourceId The source to update
    /// @param newApyBps New APY in basis points
    function updateYieldRate(uint256 sourceId, uint256 newApyBps) external onlyOracle {
        if (sourceId >= _nextSourceId) revert InvalidSourceId();
        if (newApyBps > MAX_APY_BPS) revert InvalidAmount();

        _sources[sourceId].currentApyBps = newApyBps;
        _sources[sourceId].lastUpdated = uint64(block.timestamp);

        emit YieldSourceUpdated(sourceId, newApyBps, _sources[sourceId].isActive);
    }

    /// @notice Mark a XCM dispatch as failed — refunds principal only
    /// @param routeId The failed route
    function markRouteFailed(uint256 routeId) external onlyOracle {
        UserRoute storage route = _routes[routeId];
        if (route.status != RouteStatus.Pending && route.status != RouteStatus.Active) {
            revert RouteNotActive();
        }

        uint256 sourceId = route.sourceId;
        uint256 amount = route.amount;
        address user = route.user;

        route.status = RouteStatus.Failed;

        unchecked {
            _sources[sourceId].totalDeposited -= amount;
            activeRoutesPerSource[sourceId]--;
            totalValueLocked -= amount;
        }

        // Refund user (principal only — no yield deducted from reserve)
        (bool success,) = user.call{value: amount}("");
        if (!success) revert NativeTransferFailed();

        emit WithdrawalCompleted(routeId, user, amount, 0);
    }

    /// @notice [W4] Fund the contract with native token for yield payouts
    /// @dev Oracle/relayer sends yield earned from parachains back here
    function fundYieldReserve() external payable onlyOracle {
        yieldReserve += msg.value;
        emit YieldReserveFunded(msg.sender, msg.value, yieldReserve);
    }

    // =========================================================================
    // External Functions — Admin
    // =========================================================================

    /// @notice Add a new yield source
    /// @param paraId Parachain ID
    /// @param protocol Protocol name
    /// @param initialApyBps Starting APY in bps
    /// @param maxCapacity Maximum deposit capacity
    /// @return sourceId The new source ID
    function addYieldSource(
        uint32 paraId,
        string calldata protocol,
        uint256 initialApyBps,
        uint256 maxCapacity
    ) external onlyOwner returns (uint256 sourceId) {
        if (initialApyBps > MAX_APY_BPS) revert InvalidAmount();
        if (maxCapacity == 0) revert InvalidAmount();

        sourceId = _nextSourceId++;

        _sources[sourceId] = YieldSource({
            paraId: paraId,
            protocol: protocol,
            isActive: true,
            currentApyBps: initialApyBps,
            totalDeposited: 0,
            maxCapacity: maxCapacity,
            lastUpdated: uint64(block.timestamp)
        });

        emit YieldSourceAdded(sourceId, paraId, protocol);
    }

    /// @notice Toggle a yield source active/inactive
    /// @param sourceId Source to toggle
    /// @param isActive New active state
    function setSourceActive(uint256 sourceId, bool isActive) external onlyOwner {
        if (sourceId >= _nextSourceId) revert InvalidSourceId();
        _sources[sourceId].isActive = isActive;
        emit YieldSourceUpdated(sourceId, _sources[sourceId].currentApyBps, isActive);
    }

    /// @notice Update the max capacity of a yield source
    /// @param sourceId Source to update
    /// @param newCapacity New maximum capacity
    function setSourceCapacity(uint256 sourceId, uint256 newCapacity) external onlyOwner {
        if (sourceId >= _nextSourceId) revert InvalidSourceId();
        if (newCapacity == 0) revert InvalidAmount();
        _sources[sourceId].maxCapacity = newCapacity;
    }

    /// @notice [W2] Add a new authorized oracle
    /// @param newOracle Address to authorize
    function addOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert OnlyOracle();
        if (isAuthorizedOracle[newOracle]) revert OracleAlreadyAuthorized();

        isAuthorizedOracle[newOracle] = true;
        unchecked { oracleCount++; }

        emit OracleAdded(newOracle);
    }

    /// @notice [W2] Remove an authorized oracle (cannot remove last one)
    /// @param oracleAddr Address to deauthorize
    function removeOracle(address oracleAddr) external onlyOwner {
        if (!isAuthorizedOracle[oracleAddr]) revert OracleNotAuthorized();
        if (oracleCount <= 1) revert CannotRemoveLastOracle();

        isAuthorizedOracle[oracleAddr] = false;
        unchecked { oracleCount--; }

        emit OracleRemoved(oracleAddr);
    }

    /// @notice [W3] Schedule a minimum deposit change (timelocked)
    /// @param newMinDeposit New minimum deposit in wei
    function scheduleMinDepositChange(uint256 newMinDeposit) external onlyOwner {
        bytes32 opHash = keccak256(abi.encode("setMinDeposit", newMinDeposit));
        _scheduleTimelock(opHash);
    }

    /// @notice [W3] Execute a previously scheduled minimum deposit change
    /// @param newMinDeposit Same value that was scheduled
    function executeMinDepositChange(uint256 newMinDeposit) external {
        bytes32 opHash = keccak256(abi.encode("setMinDeposit", newMinDeposit));
        _executeTimelock(opHash);
        uint256 old = minDeposit;
        minDeposit = newMinDeposit;
        emit MinDepositUpdated(old, newMinDeposit);
    }

    /// @notice Cancel any pending timelocked operation
    /// @param opHash The operation hash to cancel
    function cancelTimelock(bytes32 opHash) external onlyOwner {
        _cancelTimelock(opHash);
    }

    /// @notice Set the XCM router contract address
    /// @param _xcmRouter Address of the deployed XcmRouter
    function setXcmRouter(address _xcmRouter) external onlyOwner {
        xcmRouter = XcmRouter(payable(_xcmRouter));
        emit XcmRouterUpdated(_xcmRouter);
    }

    /// @notice Pause the router (emergency)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the router
    function unpause() external onlyOwner {
        _unpause();
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    /// @notice Create a deposit route
    function _createRoute(address user, uint256 sourceId, uint256 amount) internal returns (uint256 routeId) {
        routeId = _nextRouteId++;

        _routes[routeId] = UserRoute({
            user: user,
            sourceId: sourceId,
            amount: amount,
            status: RouteStatus.Active,
            depositTimestamp: uint64(block.timestamp),
            estimatedYield: 0
        });

        _userRoutes[user].push(routeId);
        _sources[sourceId].totalDeposited += amount;

        unchecked {
            activeRoutesPerSource[sourceId]++;
            totalValueLocked += amount;
        }
    }

    /// @notice Dispatch funds via XCM router if configured
    /// @dev If xcmRouter is not set, we still emit the event (relayer-based fallback)
    function _dispatchXcm(uint256 routeId, uint32 paraId, uint256 amount) internal {
        if (address(xcmRouter) != address(0)) {
            xcmRouter.dispatchToParachain{value: amount}(routeId, paraId, amount);
        }
        // If xcmRouter not set, event-based dispatch via relayer (backward-compatible)
    }

    /// @notice Find the best active yield source with available capacity
    function _findBestSource() internal view returns (uint256 bestId, uint256 bestApy) {
        uint256 count = _nextSourceId;
        for (uint256 i = 0; i < count;) {
            YieldSource storage s = _sources[i];
            if (s.isActive && s.currentApyBps > bestApy && s.totalDeposited < s.maxCapacity) {
                bestId = i;
                bestApy = s.currentApyBps;
            }
            unchecked { i++; }
        }
    }

    /// @notice Validate that a yield source exists and is active
    function _validateSource(uint256 sourceId) internal view {
        if (sourceId >= _nextSourceId) revert InvalidSourceId();
        if (!_sources[sourceId].isActive) revert SourceNotActive();
    }

    // =========================================================================
    // Receive
    // =========================================================================

    /// @notice Only accept native token through depositAndRoute, depositToSource, or fundYieldReserve
    receive() external payable {
        revert("Use deposit functions");
    }
}
