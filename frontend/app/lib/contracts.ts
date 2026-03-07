/**
 * OmniShield Full Protocol Contracts
 *
 * ABIs and addresses for all deployed contracts on Polkadot Hub TestNet (V6).
 */
import { ethers } from "ethers";
import { CONTRACT_ADDRESSES, POLKADOT_HUB_TESTNET } from "./stealth";

// Re-export for convenience
export { CONTRACT_ADDRESSES, POLKADOT_HUB_TESTNET };

// ============================================================================
// ABIs
// ============================================================================

export const ESCROW_ABI = [
  "function createEscrowNative(address recipient, uint64 expiresAt, bytes32 releaseConditionHash) payable returns (uint256)",
  "function createEscrowToken(address token, address recipient, uint256 amount, uint64 expiresAt, bytes32 releaseConditionHash) returns (uint256)",
  "function release(uint256 escrowId, bytes conditionData)",
  "function refund(uint256 escrowId)",
  "function dispute(uint256 escrowId)",
  "function resolveDispute(uint256 escrowId, bool releaseToRecipient)",
  "function getEscrow(uint256 escrowId) view returns (tuple(address depositor, address recipient, address token, uint256 amount, uint256 fee, uint8 state, uint64 createdAt, uint64 expiresAt, bytes32 releaseConditionHash))",
  "function getEscrowCount() view returns (uint256)",
  "function getDepositorEscrows(address depositor) view returns (uint256[])",
  "function getDepositorEscrowsPaginated(address depositor, uint256 offset, uint256 limit) view returns (uint256[], uint256)",
  "function getRecipientEscrows(address recipient) view returns (uint256[])",
  "function getRecipientEscrowsPaginated(address recipient, uint256 offset, uint256 limit) view returns (uint256[], uint256)",
  "function accumulatedFees(address token) view returns (uint256)",
  "function totalActiveEscrowAmount(address token) view returns (uint256)",
  "function protocolFeeBps() view returns (uint256)",
  "function feeCollector() view returns (address)",
  "function owner() view returns (address)",
  "function paused() view returns (bool)",
  "event EscrowCreated(uint256 indexed escrowId, address indexed depositor, address indexed recipient, address token, uint256 amount, uint64 expiresAt, bytes32 releaseConditionHash)",
  "event EscrowReleased(uint256 indexed escrowId, address indexed recipient, uint256 amount, uint256 fee)",
  "event EscrowRefunded(uint256 indexed escrowId, address indexed depositor, uint256 amount)",
  "event EscrowDisputed(uint256 indexed escrowId, address indexed disputant)",
  "event DisputeResolved(uint256 indexed escrowId, bool releasedToRecipient)",
];

export const YIELD_ROUTER_ABI = [
  "function depositAndRoute() payable returns (uint256)",
  "function depositToSource(uint256 sourceId) payable returns (uint256)",
  "function initiateWithdrawal(uint256 routeId)",
  "function completeWithdrawal(uint256 routeId, uint256 yieldEarned)",
  "function getBestYieldSource() view returns (uint256, uint256)",
  "function getYieldSource(uint256 sourceId) view returns (tuple(uint32 paraId, string protocol, bool isActive, uint256 currentApyBps, uint256 totalDeposited, uint256 maxCapacity, uint64 lastUpdated))",
  "function getYieldSourceCount() view returns (uint256)",
  "function getUserRoute(uint256 routeId) view returns (tuple(address user, uint256 sourceId, uint256 amount, uint8 status, uint64 depositTimestamp, uint256 estimatedYield))",
  "function getUserRouteIds(address user) view returns (uint256[])",
  "function getUserActiveRoutes(address user) view returns (uint256[])",
  "function getUserActiveRoutesPaginated(address user, uint256 offset, uint256 limit) view returns (uint256[], uint256)",
  "function getRouteCount() view returns (uint256)",
  "function totalValueLocked() view returns (uint256)",
  "function yieldReserve() view returns (uint256)",
  "function minDeposit() view returns (uint256)",
  "function activeRoutesPerSource(uint256 sourceId) view returns (uint256)",
  "function owner() view returns (address)",
  "function paused() view returns (bool)",
  "event DepositRouted(uint256 indexed routeId, address indexed user, uint256 indexed sourceId, uint256 amount, uint32 paraId)",
  "event WithdrawalInitiated(uint256 indexed routeId, address indexed user, uint256 amount)",
  "event WithdrawalCompleted(uint256 indexed routeId, address indexed user, uint256 amount, uint256 yieldEarned)",
  "event AutoRebalanced(uint256 indexed routeId, uint256 fromSourceId, uint256 toSourceId, uint256 amount)",
  "event YieldSourceAdded(uint256 indexed sourceId, uint32 paraId, string protocol)",
  "event YieldSourceUpdated(uint256 indexed sourceId, uint256 newApyBps, bool isActive)",
];

export const XCM_ROUTER_ABI = [
  "function dispatchToParachain(uint256 routeId, uint32 paraId, uint256 amount) payable returns (uint256)",
  "function confirmDispatch(uint256 dispatchId)",
  "function getDispatch(uint256 dispatchId) view returns (tuple(uint256 routeId, uint32 paraId, uint256 amount, uint8 status, bytes32 xcmMessageHash, uint64 dispatchedAt, uint64 confirmedAt, uint64 timeoutAt))",
  "function getDispatchCount() view returns (uint256)",
  "function getDispatchForRoute(uint256 routeId) view returns (uint256)",
  "function pendingDispatches() view returns (uint256)",
  "function amountInTransit() view returns (uint256)",
  "function isTimedOut(uint256 dispatchId) view returns (bool)",
  "function xcmPrecompileAvailable() view returns (bool)",
  "function parachainBeneficiary(uint32 paraId) view returns (bytes32)",
  "function parachainRouteConfig(uint32 paraId) view returns (uint32, bytes32, uint64, uint64)",
  "function owner() view returns (address)",
  "function paused() view returns (bool)",
  "event XcmDispatched(uint256 indexed dispatchId, uint256 indexed routeId, uint32 indexed paraId, uint256 amount, bytes32 xcmMessageHash)",
  "event XcmConfirmed(uint256 indexed dispatchId, uint256 indexed routeId, uint32 paraId)",
  "event XcmFailed(uint256 indexed dispatchId, uint256 indexed routeId, uint32 paraId, string reason)",
  "event XcmReturnInitiated(uint256 indexed dispatchId, uint256 indexed routeId, uint256 amount, uint256 yieldEarned)",
  "event XcmReturnConfirmed(uint256 indexed dispatchId, uint256 indexed routeId, uint256 amountReturned)",
  "event XcmTimedOut(uint256 indexed dispatchId, uint256 indexed routeId)",
];

export const CRYPTO_REGISTRY_ABI = [
  "function verifySr25519Signature(bytes32 pubkey, bytes signature, bytes message) view returns (bool)",
  "function verifyEd25519Signature(bytes32 pubkey, bytes32 sigR, bytes32 sigS, bytes message) view returns (bool)",
  "function blake2b256(bytes data) view returns (bytes32)",
  "function computeStealthAddress(bytes32 spendingPubKey, bytes32 sharedSecretHash) view returns (address)",
  "function verifyStealthDerivation(bytes32 spendingPubKey, bytes32 sharedSecretHash, address expected) view returns (bool)",
  "function sr25519Available() view returns (bool)",
  "function ed25519Available() view returns (bool)",
  "function blake2fAvailable() view returns (bool)",
  "function bn128Available() view returns (bool)",
  "function getPrecompileStatus() view returns (tuple(bool sr25519, bool ed25519, bool blake2f, bool bn128))",
  "event PrecompileDetected(string indexed name, address precompileAddr, bool available)",
];

export const HUB_ABI = [
  "function escrow() view returns (address)",
  "function stealthPayment() view returns (address)",
  "function yieldRouter() view returns (address)",
  "function cryptoRegistry() view returns (address)",
  "function owner() view returns (address)",
  "function paused() view returns (bool)",
];

// ============================================================================
// Contract Factory
// ============================================================================

export function getContracts(signerOrProvider: ethers.Signer | ethers.Provider) {
  return {
    escrow: new ethers.Contract(CONTRACT_ADDRESSES.escrow, ESCROW_ABI, signerOrProvider),
    yieldRouter: new ethers.Contract(CONTRACT_ADDRESSES.yieldRouter, YIELD_ROUTER_ABI, signerOrProvider),
    xcmRouter: new ethers.Contract(CONTRACT_ADDRESSES.xcmRouter, XCM_ROUTER_ABI, signerOrProvider),
    cryptoRegistry: new ethers.Contract(CONTRACT_ADDRESSES.cryptoRegistry, CRYPTO_REGISTRY_ABI, signerOrProvider),
    hub: new ethers.Contract(CONTRACT_ADDRESSES.omniShieldHub, HUB_ABI, signerOrProvider),
  };
}

// ============================================================================
// Utility - Escrow State Enum
// ============================================================================

export const ESCROW_STATES = ["Active", "Released", "Refunded", "Disputed", "Expired"] as const;
export type EscrowStateName = (typeof ESCROW_STATES)[number];

export const ROUTE_STATUSES = ["Pending", "Active", "Withdrawing", "Completed", "Failed"] as const;
export type RouteStatusName = (typeof ROUTE_STATUSES)[number];

export const XCM_STATUSES = ["Pending", "Dispatched", "Confirmed", "Failed", "TimedOut", "Returning", "Returned"] as const;
export type XcmStatusName = (typeof XCM_STATUSES)[number];

// Parachain metadata
export const PARACHAINS: Record<number, { name: string; color: string; icon: string }> = {
  2030: { name: "Bifrost", color: "#7B3FE4", icon: "🔮" },
  2034: { name: "HydraDX", color: "#4AE4C7", icon: "💧" },
  2000: { name: "Acala", color: "#E44AB2", icon: "🔴" },
};
