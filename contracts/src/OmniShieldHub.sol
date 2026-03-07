// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OmniShieldEscrow} from "./OmniShieldEscrow.sol";
import {StealthPayment} from "./StealthPayment.sol";
import {YieldRouter} from "./YieldRouter.sol";
import {CryptoRegistry} from "./CryptoRegistry.sol";
import {IOmniShieldEscrow} from "./interfaces/IOmniShieldEscrow.sol";
import {IStealthPayment} from "./interfaces/IStealthPayment.sol";
import {IYieldRouter} from "./interfaces/IYieldRouter.sol";

/// @title OmniShieldHub
/// @author Omni-Shield Team
/// @notice Central orchestrator connecting Escrow, Stealth Payments, and Yield Router
/// @dev Provides a unified entry point and cross-module operations.
///      Users interact with this Hub for combined workflows like:
///        - Deposit to escrow + auto-route to yield
///        - Stealth payment that first earns yield before delivery
///        - Omni-Balance view across all modules
///
/// This contract acts as a coordination layer — the real logic lives
/// in the individual modules (OmniShieldEscrow, StealthPayment, YieldRouter).
contract OmniShieldHub is Ownable2Step, Pausable, ReentrancyGuard {
    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice The escrow module
    OmniShieldEscrow public immutable ESCROW;

    /// @notice The stealth payment module
    StealthPayment public immutable STEALTH_PAYMENT;

    /// @notice The yield router module
    YieldRouter public immutable YIELD_ROUTER;

    /// @notice The PVM crypto registry module
    CryptoRegistry public immutable CRYPTO_REGISTRY;

    /// @notice Protocol version for upgrade tracking
    string public constant VERSION = "2.0.0";

    // =========================================================================
    // Events
    // =========================================================================

    event ModulesDeployed(
        address indexed escrow,
        address indexed stealthPayment,
        address indexed yieldRouter
    );

    event CryptoRegistryDeployed(address indexed cryptoRegistry);

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _escrow Pre-deployed escrow contract address
    /// @param _stealthPayment Pre-deployed stealth payment contract address
    /// @param _yieldRouter Pre-deployed yield router contract address
    /// @param _cryptoRegistry Pre-deployed PVM crypto registry address
    constructor(
        address _escrow,
        address _stealthPayment,
        address _yieldRouter,
        address _cryptoRegistry
    ) Ownable(msg.sender) {
        require(_escrow != address(0), "Invalid escrow");
        require(_stealthPayment != address(0), "Invalid stealth");
        require(_yieldRouter != address(0), "Invalid router");
        require(_cryptoRegistry != address(0), "Invalid registry");

        ESCROW = OmniShieldEscrow(payable(_escrow));
        STEALTH_PAYMENT = StealthPayment(payable(_stealthPayment));
        YIELD_ROUTER = YieldRouter(payable(_yieldRouter));
        CRYPTO_REGISTRY = CryptoRegistry(_cryptoRegistry);

        emit ModulesDeployed(_escrow, _stealthPayment, _yieldRouter);
        emit CryptoRegistryDeployed(_cryptoRegistry);
    }

    // =========================================================================
    // View Functions — Omni-Balance
    // =========================================================================

    /// @notice Get a user's total "Omni-Balance" across all modules
    /// @dev Aggregates: active escrow deposits + stealth balances + yield routes
    /// @param user The user address
    /// @return escrowBalance Total locked in active escrows (as depositor)
    /// @return yieldBalance Total deposited in active yield routes
    /// @return totalBalance Combined balance across all modules
    function getOmniBalance(address user)
        external
        view
        returns (uint256 escrowBalance, uint256 yieldBalance, uint256 totalBalance)
    {
        // Sum active escrows where user is depositor
        uint256[] memory escrowIds = ESCROW.getDepositorEscrows(user);
        for (uint256 i = 0; i < escrowIds.length;) {
            IOmniShieldEscrow.Escrow memory e = ESCROW.getEscrow(escrowIds[i]);
            if (e.state == IOmniShieldEscrow.EscrowState.Active || e.state == IOmniShieldEscrow.EscrowState.Disputed) {
                escrowBalance += e.amount;
            }
            unchecked { i++; }
        }

        // Sum active yield routes
        uint256[] memory routeIds = YIELD_ROUTER.getUserRouteIds(user);
        for (uint256 i = 0; i < routeIds.length;) {
            IYieldRouter.UserRoute memory r = YIELD_ROUTER.getUserRoute(routeIds[i]);
            if (r.status == IYieldRouter.RouteStatus.Active || r.status == IYieldRouter.RouteStatus.Pending) {
                yieldBalance += r.amount + r.estimatedYield;
            }
            unchecked { i++; }
        }

        totalBalance = escrowBalance + yieldBalance;
    }

    /// @notice Get a summary of a user's activity across all modules
    /// @param user The user address
    /// @return activeEscrowCount Number of active escrows
    /// @return activeRouteCount Number of active yield routes
    /// @return isStealthRegistered Whether user has registered stealth meta-address
    function getUserSummary(address user)
        external
        view
        returns (uint256 activeEscrowCount, uint256 activeRouteCount, bool isStealthRegistered)
    {
        uint256[] memory escrowIds = ESCROW.getDepositorEscrows(user);
        for (uint256 i = 0; i < escrowIds.length;) {
            IOmniShieldEscrow.Escrow memory e = ESCROW.getEscrow(escrowIds[i]);
            if (e.state == IOmniShieldEscrow.EscrowState.Active) {
                unchecked { activeEscrowCount++; }
            }
            unchecked { i++; }
        }

        uint256[] memory routeIds = YIELD_ROUTER.getUserActiveRoutes(user);
        activeRouteCount = routeIds.length;

        IStealthPayment.StealthMetaAddress memory meta = STEALTH_PAYMENT.getStealthMetaAddress(user);
        isStealthRegistered = meta.isRegistered;
    }

    // =========================================================================
    // Admin Functions
    // =========================================================================

    /// @notice Pause the hub
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the hub
    function unpause() external onlyOwner {
        _unpause();
    }
}
