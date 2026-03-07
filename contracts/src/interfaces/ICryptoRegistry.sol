// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ICryptoRegistry
/// @author Omni-Shield Team
/// @notice Interface for the PVM CryptoRegistry contract
/// @dev Used by StealthPayment, XcmRouter, and other contracts to access
///      PVM precompile cryptographic functions through a unified API.
interface ICryptoRegistry {
    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice Status of all PVM precompiles
    struct PrecompileStatus {
        bool sr25519;
        bool ed25519;
        bool blake2f;
        bool bn128;
    }

    // =========================================================================
    // Events
    // =========================================================================

    event PrecompileDetected(string indexed name, address precompileAddr, bool available);
    event Sr25519Verified(bytes32 indexed pubkeyHash, bool valid);
    event Ed25519Verified(bytes32 indexed pubkeyHash, bool valid);
    event Blake2bComputed(bytes32 indexed inputHash, bytes32 result);
    event SubstrateNonceConsumed(bytes32 indexed pubkeyHash, uint256 nonce);
    event StealthDerivationVerified(address indexed stealthAddress, bool valid);
    event CryptoRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    // =========================================================================
    // Errors
    // =========================================================================

    error Sr25519NotAvailable();
    error Ed25519NotAvailable();
    error Blake2fNotAvailable();
    error Bn128NotAvailable();
    error InvalidSignatureLength();
    error InvalidPublicKey();
    error NonceAlreadyUsed();
    error SignatureVerificationFailed();
    error BatchLengthMismatch();

    // =========================================================================
    // Signature Verification
    // =========================================================================

    /// @notice Verify an sr25519 signature (Polkadot native)
    /// @param pubkey Sr25519 public key (32 bytes)
    /// @param signature Sr25519 signature (64 bytes)
    /// @param message The signed message
    /// @return valid True if signature is valid
    function verifySr25519Signature(
        bytes32 pubkey,
        bytes calldata signature,
        bytes calldata message
    ) external view returns (bool valid);

    /// @notice Verify an ed25519 signature
    /// @param pubkey Ed25519 public key (32 bytes)
    /// @param sigR Signature R component (32 bytes)
    /// @param sigS Signature S component (32 bytes)
    /// @param message The signed message
    /// @return valid True if signature is valid
    function verifyEd25519Signature(
        bytes32 pubkey,
        bytes32 sigR,
        bytes32 sigS,
        bytes calldata message
    ) external view returns (bool valid);

    /// @notice Batch verify multiple sr25519 signatures
    function batchVerifySr25519(
        bytes32[] calldata pubkeys,
        bytes[] calldata signatures,
        bytes[] calldata messages
    ) external view returns (bool[] memory results);

    // =========================================================================
    // Hashing
    // =========================================================================

    /// @notice Compute Blake2b-256 hash
    /// @param data Input data
    /// @return hash The 32-byte Blake2b-256 hash
    function blake2b256(bytes calldata data) external view returns (bytes32 hash);

    /// @notice Compute keyed Blake2b-256 hash (HMAC-like)
    function blake2b256Keyed(bytes calldata key, bytes calldata data) external view returns (bytes32 hash);

    // =========================================================================
    // BN128 Curve Operations
    // =========================================================================

    /// @notice BN128 scalar multiplication: scalar * (px, py)
    function bn128ScalarMul(
        uint256 px,
        uint256 py,
        uint256 scalar
    ) external view returns (uint256 x, uint256 y);

    /// @notice BN128 point addition: (x1,y1) + (x2,y2)
    function bn128PointAdd(
        uint256 x1,
        uint256 y1,
        uint256 x2,
        uint256 y2
    ) external view returns (uint256 x, uint256 y);

    /// @notice Compute Pedersen commitment: value*G + blinding*H
    function computePedersenCommitment(
        uint256 value,
        uint256 blindingFactor,
        uint256 hx,
        uint256 hy
    ) external view returns (uint256 cx, uint256 cy);

    // =========================================================================
    // Stealth Address Integration
    // =========================================================================

    /// @notice Compute expected stealth address from spending key and shared secret
    function computeStealthAddress(
        bytes32 spendingPubKey,
        bytes32 sharedSecretHash
    ) external pure returns (address);

    /// @notice Verify that a stealth address was correctly derived
    function verifyStealthDerivation(
        bytes32 spendingPubKey,
        bytes32 sharedSecretHash,
        address expectedStealthAddress
    ) external pure returns (bool valid);

    // =========================================================================
    // XCM Message Authentication
    // =========================================================================

    /// @notice Compute Blake2b-based XCM message hash (matches substrate-side hashing)
    function computeBlake2bXcmHash(
        uint256 routeId,
        uint32 paraId,
        uint256 amount,
        bytes32 beneficiary,
        uint256 nonce
    ) external view returns (bytes32);

    /// @notice Verify XCM message authentication with substrate signature
    function verifyXcmMessageAuth(
        bytes32 messageHash,
        bytes32 pubkey,
        bytes calldata signature
    ) external view returns (bool valid);

    // =========================================================================
    // Substrate Auth (Nonce Management)
    // =========================================================================

    /// @notice Get the next expected nonce for a substrate public key
    function getSubstrateNonce(bytes32 pubkeyHash) external view returns (uint256);

    /// @notice Verify a substrate auth message and consume the nonce
    /// @dev State-changing: increments the nonce for the pubkey
    function consumeSubstrateAuth(
        bytes32 pubkey,
        bytes calldata signature,
        bytes calldata message,
        uint256 expectedNonce
    ) external returns (bool valid);

    // =========================================================================
    // Precompile Status
    // =========================================================================

    function sr25519Available() external view returns (bool);
    function ed25519Available() external view returns (bool);
    function blake2fAvailable() external view returns (bool);
    function bn128Available() external view returns (bool);
    function getPrecompileStatus() external view returns (PrecompileStatus memory);
}
