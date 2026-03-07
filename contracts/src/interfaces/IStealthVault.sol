// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IStealthVault
/// @author Omni-Shield Team
/// @notice Interface for the commitment-based stealth privacy vault
/// @dev Day 12-14 deliverable — provides enhanced privacy through:
///      1. Pedersen commitment deposits (amount hidden on-chain)
///      2. Nullifier-based withdrawals (unlinkable deposit→withdrawal)
///      3. Relayer support for gasless withdrawals
///      4. Batch stealth operations
///      5. View tag scanning helpers
interface IStealthVault {
    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice A commitment deposit entry in the vault
    /// @param commitment Pedersen commitment C = value*G + blinding*H
    /// @param token Token address (address(0) for native)
    /// @param timestamp When the deposit was made
    /// @param withdrawn Whether the deposit has been withdrawn via nullifier
    struct CommitmentDeposit {
        bytes32 commitment;
        address token;
        uint64 timestamp;
        bool withdrawn;
    }

    /// @notice Batch stealth payment parameters
    /// @param stealthAddress Destination stealth address
    /// @param amount Amount to send (native) or 0 for equal split
    /// @param ephemeralPubKey Ephemeral public key for announcement
    /// @param viewTag View tag for efficient scanning
    struct BatchStealthPayment {
        address stealthAddress;
        uint256 amount;
        bytes32 ephemeralPubKey;
        uint8 viewTag;
    }

    /// @notice Relayer withdrawal request
    /// @param stealthAddress The stealth address holding funds
    /// @param token Token to withdraw
    /// @param to Final destination address
    /// @param relayerFee Fee paid to the relayer from the withdrawal
    /// @param deadline Timestamp deadline for the withdrawal
    struct RelayerWithdrawal {
        address stealthAddress;
        address token;
        address to;
        uint256 relayerFee;
        uint256 deadline;
    }

    /// @notice Stealth scan result — returned by view functions
    /// @param stealthAddress The stealth address that received funds
    /// @param token Token address
    /// @param amount Amount deposited
    /// @param ephemeralPubKey Ephemeral key for deriving stealth private key
    /// @param viewTag View tag for quick filtering
    /// @param timestamp Block timestamp of the payment
    struct StealthScanEntry {
        address stealthAddress;
        address token;
        uint256 amount;
        bytes32 ephemeralPubKey;
        uint8 viewTag;
        uint64 timestamp;
    }

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a commitment deposit is made
    event CommitmentDeposited(
        uint256 indexed depositIndex,
        bytes32 indexed commitment,
        address token,
        uint256 amount,
        uint64 timestamp
    );

    /// @notice Emitted when a nullifier withdrawal is completed
    event NullifierWithdrawal(
        bytes32 indexed nullifier,
        address indexed to,
        address token,
        uint256 amount,
        address relayer
    );

    /// @notice Emitted when a batch stealth payment is processed
    event BatchStealthProcessed(
        address indexed sender,
        uint256 count,
        uint256 totalAmount,
        address token
    );

    /// @notice Emitted when a relayer-assisted withdrawal is completed
    event RelayerWithdrawalProcessed(
        address indexed stealthAddress,
        address indexed to,
        address indexed relayer,
        address token,
        uint256 amount,
        uint256 relayerFee
    );

    /// @notice Emitted when an emergency withdrawal is initiated
    event EmergencyWithdrawalInitiated(
        uint256 indexed depositIndex,
        address indexed depositor,
        uint256 unlockTime
    );

    /// @notice Emitted when an emergency withdrawal is executed
    event EmergencyWithdrawalExecuted(
        uint256 indexed depositIndex,
        address indexed depositor,
        address token,
        uint256 amount
    );

    /// @notice Emitted when the relayer fee cap is updated
    event RelayerFeeCapUpdated(uint256 oldCap, uint256 newCap);

    /// @notice Emitted when the emergency timelock is updated
    event EmergencyTimelockUpdated(uint256 oldTimelock, uint256 newTimelock);

    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidCommitment();
    error InvalidNullifier();
    error NullifierAlreadyUsed();
    error InvalidAmount();
    error InvalidAddress();
    error CommitmentMismatch();
    error DepositAlreadyWithdrawn();
    error DepositNotFound();
    error InsufficientBalance();
    error TransferFailed();
    error BatchTooLarge();
    error BatchAmountMismatch();
    error RelayerFeeTooHigh();
    error WithdrawalExpired();
    error InvalidSignature();
    error EmergencyTimelockNotElapsed();
    error EmergencyNotInitiated();
    error NotDepositor();
    error StealthPaymentNotSet();

    // =========================================================================
    // Functions — Commitment Deposits
    // =========================================================================

    /// @notice Deposit native token with a Pedersen commitment
    /// @dev The commitment hides the amount: C = keccak256(value, blinding, depositor)
    ///      On-chain, only the commitment is stored. The amount is passed for the actual
    ///      transfer but verified against the commitment during withdrawal.
    /// @param commitment The Pedersen commitment hash
    function depositWithCommitment(bytes32 commitment) external payable;

    /// @notice Deposit ERC20 token with a Pedersen commitment
    /// @param token ERC20 token address
    /// @param amount Amount to deposit
    /// @param commitment The Pedersen commitment hash
    function depositTokenWithCommitment(
        address token,
        uint256 amount,
        bytes32 commitment
    ) external;

    /// @notice Withdraw funds using a nullifier (unlinkable to deposit)
    /// @dev The nullifier is hash(secret). The caller proves knowledge of the
    ///      deposit secret without revealing which deposit they're withdrawing from.
    /// @param nullifier The nullifier (prevents double-spend)
    /// @param depositIndex Index of the deposit to withdraw
    /// @param amount The deposited amount (must match commitment)
    /// @param blindingFactor Blinding factor used in the commitment
    /// @param to Destination address for funds
    function withdrawWithNullifier(
        bytes32 nullifier,
        uint256 depositIndex,
        uint256 amount,
        bytes32 blindingFactor,
        address to
    ) external;

    // =========================================================================
    // Functions — Batch Operations
    // =========================================================================

    /// @notice Send native token to multiple stealth addresses in one transaction
    /// @param payments Array of batch stealth payment parameters
    /// @param metadata Shared metadata for all payments
    function batchSendNativeToStealth(
        BatchStealthPayment[] calldata payments,
        bytes calldata metadata
    ) external payable;

    /// @notice Send ERC20 token to multiple stealth addresses in one transaction
    /// @param token ERC20 token address
    /// @param payments Array of batch stealth payment parameters
    /// @param metadata Shared metadata for all payments
    function batchSendTokenToStealth(
        address token,
        BatchStealthPayment[] calldata payments,
        bytes calldata metadata
    ) external;

    // =========================================================================
    // Functions — Relayer Withdrawals
    // =========================================================================

    /// @notice Withdraw from a stealth address via a relayer (gasless for user)
    /// @dev The stealth address owner signs the withdrawal parameters off-chain.
    ///      The relayer submits the tx, pays gas, and takes a fee from the withdrawal.
    /// @param withdrawal Relayer withdrawal parameters
    /// @param v ECDSA v
    /// @param r ECDSA r
    /// @param s ECDSA s
    function withdrawViaRelayer(
        RelayerWithdrawal calldata withdrawal,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    // =========================================================================
    // Functions — Emergency
    // =========================================================================

    /// @notice Initiate emergency withdrawal (starts timelock)
    /// @dev Only the original depositor can initiate. Must wait emergencyTimelock seconds.
    /// @param depositIndex The deposit index to recover
    function initiateEmergencyWithdrawal(uint256 depositIndex) external;

    /// @notice Execute an emergency withdrawal after timelock elapses
    /// @param depositIndex The deposit index to recover
    /// @param amount Amount deposited
    /// @param blindingFactor Blinding factor for commitment verification
    function executeEmergencyWithdrawal(
        uint256 depositIndex,
        uint256 amount,
        bytes32 blindingFactor
    ) external;

    // =========================================================================
    // Functions — Scanning Helpers
    // =========================================================================

    /// @notice Compute a view tag from a shared secret
    /// @param sharedSecret The ECDH shared secret
    /// @return viewTag The first byte of keccak256(sharedSecret)
    function computeViewTag(bytes32 sharedSecret) external pure returns (uint8 viewTag);

    /// @notice Compute the expected stealth address from meta-address + ephemeral key
    /// @dev Helper to verify stealth addresses off-chain
    /// @param spendingPubKey Recipient's spending public key
    /// @param sharedSecretHash Hash of the ECDH shared secret
    /// @return stealthAddress The derived stealth address
    function computeStealthAddress(
        bytes32 spendingPubKey,
        bytes32 sharedSecretHash
    ) external pure returns (address stealthAddress);

    // =========================================================================
    // Functions — Views
    // =========================================================================

    /// @notice Get deposit count
    function getDepositCount() external view returns (uint256);

    /// @notice Get a commitment deposit by index
    function getDeposit(uint256 index) external view returns (CommitmentDeposit memory);

    /// @notice Check if a nullifier has been used
    function isNullifierUsed(bytes32 nullifier) external view returns (bool);

    /// @notice Get the relayer fee cap (basis points)
    function relayerFeeCap() external view returns (uint256);

    /// @notice Get the emergency timelock duration
    function emergencyTimelock() external view returns (uint256);
}
