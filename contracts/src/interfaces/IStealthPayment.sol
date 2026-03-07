// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IStealthPayment
/// @notice Interface for the stealth address payment system
/// @dev Implements a simplified EIP-5564 pattern for Polkadot Hub
interface IStealthPayment {
    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice Registry entry for a user's stealth meta-address
    /// @param spendingPubKey Public key used to derive stealth addresses
    /// @param viewingPubKey Public key used by senders to generate stealth addresses
    /// @param isRegistered Whether the user has registered
    struct StealthMetaAddress {
        bytes32 spendingPubKey;
        bytes32 viewingPubKey;
        bool isRegistered;
    }

    /// @notice Record of a stealth payment
    /// @param stealthAddress The one-time stealth address receiving funds
    /// @param ephemeralPubKey Ephemeral public key for the recipient to locate payment
    /// @param token Token address (address(0) for native)
    /// @param amount Amount sent
    /// @param timestamp When the payment was made
    /// @param viewTag First byte of shared secret for efficient scanning
    struct StealthPaymentRecord {
        address stealthAddress;
        bytes32 ephemeralPubKey;
        address token;
        uint256 amount;
        uint64 timestamp;
        uint8 viewTag;
    }

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a user registers their stealth meta-address
    event StealthMetaAddressRegistered(
        address indexed registrant,
        bytes32 spendingPubKey,
        bytes32 viewingPubKey
    );

    /// @notice Emitted when a stealth payment announcement is made (EIP-5564 style)
    /// @dev Recipients scan these events using their viewing key to detect payments
    event Announcement(
        uint256 indexed schemeId,
        address indexed stealthAddress,
        address indexed caller,
        bytes32 ephemeralPubKey,
        bytes metadata
    );

    /// @notice Emitted when native token is sent to a stealth address
    event StealthPaymentSent(
        address indexed stealthAddress,
        bytes32 indexed ephemeralPubKey,
        address token,
        uint256 amount,
        uint8 viewTag
    );

    /// @notice Emitted when a stealth address withdraws funds
    event StealthWithdrawal(address indexed stealthAddress, address indexed to, address token, uint256 amount);

    // =========================================================================
    // Errors
    // =========================================================================

    error AlreadyRegistered();
    error NotRegistered();
    error InvalidPubKey();
    error InvalidStealthAddress();
    error InvalidAmount();
    error InsufficientBalance();
    error TransferFailed();
    error Unauthorized();
    error InvalidSignature();
    error InvalidNonce();
    error ExpiredDeadline();
    error CryptoRegistryNotSet();

    // =========================================================================
    // PVM Crypto Events
    // =========================================================================

    /// @notice Emitted when CryptoRegistry is configured
    event CryptoRegistrySet(address indexed cryptoRegistry);

    /// @notice Emitted when a Substrate account authorizes a stealth payment via sr25519
    event SubstrateStealthPayment(
        address indexed stealthAddress,
        bytes32 indexed substratePubKey,
        uint256 amount,
        uint256 nonce
    );

    /// @notice Emitted when stealth address derivation is verified on-chain
    event StealthDerivationVerified(
        address indexed stealthAddress,
        bytes32 indexed spendingPubKey,
        bool valid
    );

    /// @notice Emitted when a relayer-assisted withdrawal is processed
    event RelayerWithdrawalProcessed(
        address indexed stealthAddress,
        address indexed to,
        address indexed relayer,
        address token,
        uint256 amount,
        uint256 relayerFee
    );

    // =========================================================================
    // Functions
    // =========================================================================

    /// @notice Register a stealth meta-address for receiving private payments
    /// @param spendingPubKey The public spending key (compressed, 32 bytes)
    /// @param viewingPubKey The public viewing key (compressed, 32 bytes)
    function registerStealthMetaAddress(bytes32 spendingPubKey, bytes32 viewingPubKey) external;

    /// @notice Update an existing stealth meta-address
    /// @param spendingPubKey New public spending key
    /// @param viewingPubKey New public viewing key
    function updateStealthMetaAddress(bytes32 spendingPubKey, bytes32 viewingPubKey) external;

    /// @notice Send native token to a stealth address with announcement
    /// @param stealthAddress The computed one-time stealth address
    /// @param ephemeralPubKey Ephemeral public key for recipient discovery
    /// @param viewTag View tag for efficient scanning (first byte of shared secret)
    /// @param metadata Additional encrypted metadata
    function sendNativeToStealth(
        address stealthAddress,
        bytes32 ephemeralPubKey,
        uint8 viewTag,
        bytes calldata metadata
    ) external payable;

    /// @notice Send ERC20 token to a stealth address with announcement
    /// @param token ERC20 token address
    /// @param amount Amount to send
    /// @param stealthAddress The computed one-time stealth address
    /// @param ephemeralPubKey Ephemeral public key for recipient discovery
    /// @param viewTag View tag for efficient scanning
    /// @param metadata Additional encrypted metadata
    function sendTokenToStealth(
        address token,
        uint256 amount,
        address stealthAddress,
        bytes32 ephemeralPubKey,
        uint8 viewTag,
        bytes calldata metadata
    ) external;

    /// @notice Withdraw funds from a stealth address
    /// @dev Called by the stealth address holder (recipient who derived the private key)
    /// @param token Token to withdraw (address(0) for native)
    /// @param to Destination address
    function withdrawFromStealth(address token, address to) external;

    /// @notice Get the stealth meta-address for a user
    /// @param user Address of the registered user
    /// @return metaAddress The stealth meta-address record
    function getStealthMetaAddress(address user) external view returns (StealthMetaAddress memory metaAddress);

    /// @notice Get the balance of a stealth address
    /// @param stealthAddress The stealth address to check
    /// @param token Token address (address(0) for native)
    /// @return balance The token balance held for that stealth address
    function getStealthBalance(address stealthAddress, address token) external view returns (uint256 balance);

    /// @notice Get the total number of announcements (for scanning)
    function getAnnouncementCount() external view returns (uint256);

    // =========================================================================
    // PVM Crypto Functions
    // =========================================================================

    /// @notice Send native token to stealth address authorized by a Substrate sr25519 signature
    /// @dev Enables gasless stealth payments for Polkadot.js / Talisman wallet users.
    ///      The Substrate account signs the payment parameters with sr25519, and anyone
    ///      can submit the transaction (relayer pays gas). The sr25519 signature is
    ///      verified on-chain via the PVM sr25519 precompile (schnorrkel Rust crate).
    /// @param stealthAddress The computed stealth address
    /// @param ephemeralPubKey Ephemeral public key for discovery
    /// @param viewTag View tag for scanning
    /// @param metadata Encrypted metadata
    /// @param substratePubKey The sr25519 public key of the authorizing Substrate account
    /// @param signature The sr25519 signature (64 bytes) over the payment parameters
    /// @param nonce Anti-replay nonce for the Substrate account
    /// @param deadline Timestamp deadline for the authorization
    function sendNativeWithSubstrateAuth(
        address stealthAddress,
        bytes32 ephemeralPubKey,
        uint8 viewTag,
        bytes calldata metadata,
        bytes32 substratePubKey,
        bytes calldata signature,
        uint256 nonce,
        uint256 deadline
    ) external payable;

    /// @notice Verify that a stealth address was correctly derived via CryptoRegistry
    /// @param spendingPubKey The spending public key from the meta-address registry
    /// @param sharedSecretHash Hash of the ECDH shared secret
    /// @param stealthAddress The stealth address to verify
    /// @return valid True if the derivation is correct
    function verifyStealthDerivation(
        bytes32 spendingPubKey,
        bytes32 sharedSecretHash,
        address stealthAddress
    ) external view returns (bool valid);
}
