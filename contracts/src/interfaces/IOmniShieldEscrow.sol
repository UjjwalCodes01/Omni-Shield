// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IOmniShieldEscrow
/// @notice Interface for the Omni-Shield core escrow contract
/// @dev All amounts denominated in the deposit token's native decimals
interface IOmniShieldEscrow {
    // =========================================================================
    // Enums
    // =========================================================================

    /// @notice Possible states of an escrow
    enum EscrowState {
        Active,     // Funds deposited, awaiting release or refund
        Released,   // Funds released to recipient
        Refunded,   // Funds returned to depositor
        Disputed,   // Under dispute resolution
        Expired     // Past deadline, eligible for refund
    }

    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice Complete escrow record
    /// @param depositor Address that created the escrow
    /// @param recipient Address that will receive funds upon release
    /// @param token ERC20 token address (address(0) for native token)
    /// @param amount Net deposited amount (after fees)
    /// @param fee Protocol fee deducted
    /// @param state Current escrow state
    /// @param createdAt Block timestamp when escrow was created
    /// @param expiresAt Block timestamp after which escrow can be refunded
    /// @param releaseConditionHash Keccak256 hash of the release condition data
    struct Escrow {
        address depositor;
        address recipient;
        address token;
        uint256 amount;
        uint256 fee;
        EscrowState state;
        uint64 createdAt;
        uint64 expiresAt;
        bytes32 releaseConditionHash;
    }

    // =========================================================================
    // Events
    // =========================================================================

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

    event EmergencyWithdraw(address indexed token, uint256 amount);

    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidRecipient();
    error InvalidAmount();
    error InvalidExpiry();
    error InvalidFeeBps();
    error InvalidFeeCollector();
    error EscrowNotActive();
    error EscrowNotExpired();
    error EscrowNotDisputed();
    error OnlyDepositor();
    error OnlyRecipient();
    error OnlyDepositorOrRecipient();
    error InvalidCondition();
    error TransferFailed();
    error NativeTokenTransferFailed();
    error FeeTooHigh();

    /// @notice W1: Thrown when emergencyWithdraw attempts to take protected funds
    error ExceedsAvailableBalance();

    // =========================================================================
    // Functions
    // =========================================================================

    /// @notice Create a new escrow with native token (DOT)
    /// @param recipient Funds receiver address
    /// @param expiresAt Unix timestamp for escrow expiry
    /// @param releaseConditionHash Hash of the release condition
    /// @return escrowId Unique identifier for the new escrow
    function createEscrowNative(
        address recipient,
        uint64 expiresAt,
        bytes32 releaseConditionHash
    ) external payable returns (uint256 escrowId);

    /// @notice Create a new escrow with ERC20 token
    /// @param token ERC20 token contract address
    /// @param recipient Funds receiver address
    /// @param amount Token amount to deposit
    /// @param expiresAt Unix timestamp for escrow expiry
    /// @param releaseConditionHash Hash of the release condition
    /// @return escrowId Unique identifier for the new escrow
    function createEscrowToken(
        address token,
        address recipient,
        uint256 amount,
        uint64 expiresAt,
        bytes32 releaseConditionHash
    ) external returns (uint256 escrowId);

    /// @notice Release escrow funds to recipient
    /// @param escrowId ID of the escrow to release
    /// @param conditionData Data that hashes to releaseConditionHash
    function release(uint256 escrowId, bytes calldata conditionData) external;

    /// @notice Refund an expired escrow back to depositor
    /// @param escrowId ID of the escrow to refund
    function refund(uint256 escrowId) external;

    /// @notice Dispute an active escrow (depositor or recipient only)
    /// @param escrowId ID of the escrow to dispute
    function dispute(uint256 escrowId) external;

    /// @notice Resolve a disputed escrow (admin only)
    /// @param escrowId ID of the disputed escrow
    /// @param releaseToRecipient True to release to recipient, false to refund depositor
    function resolveDispute(uint256 escrowId, bool releaseToRecipient) external;

    /// @notice Get escrow details
    /// @param escrowId ID of the escrow
    /// @return escrow The complete escrow record
    function getEscrow(uint256 escrowId) external view returns (Escrow memory escrow);

    /// @notice Get total number of escrows created
    /// @return count Total escrow count
    function getEscrowCount() external view returns (uint256 count);
}
