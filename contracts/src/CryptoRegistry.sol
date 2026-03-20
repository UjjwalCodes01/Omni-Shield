// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICryptoRegistry} from "./interfaces/ICryptoRegistry.sol";
import {PvmVerifier} from "./libraries/PvmVerifier.sol";
import {PvmBlake2} from "./libraries/PvmBlake2.sol";
import {PolkadotPrecompileAddresses, PrecompileFeatureStatus, PolkadotFeatures} from "./interfaces/IPolkadotPrecompiles.sol";

/// @title CryptoRegistry
/// @author Omni-Shield Team
/// @notice Central PVM precompile integration contract — Rust crypto called from Solidity
/// @dev This contract is the unified gateway for all Polkadot Virtual Machine (PVM)
///      cryptographic precompiles. It wraps native Rust cryptographic libraries
///      (compiled into the PVM runtime) and exposes them to Solidity contracts
///      in the Omni-Shield protocol.
///
///      PVM Precompile Architecture:
///      ┌─────────────────────────────────────────────────────────────────────┐
///      │                   Polkadot Hub Runtime (PVM)                       │
///      │                                                                     │
///      │   ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐    │
///      │   │ schnorrkel   │  │ ed25519-dalek│  │ blake2b_simd         │    │
///      │   │ (sr25519)    │  │ (ed25519)    │  │ (blake2b)            │    │
///      │   │ Rust crate   │  │ Rust crate   │  │ Rust crate           │    │
///      │   └──────┬───────┘  └──────┬───────┘  └──────────┬───────────┘    │
///      │          │ 0x0403          │ 0x0402              │ 0x0009         │
///      │   ┌──────▼─────────────────▼─────────────────────▼───────────┐    │
///      │   │              EVM Precompile Interface                     │    │
///      │   │        (staticcall from Solidity contracts)              │    │
///      │   └──────────────────────────┬───────────────────────────────┘    │
///      └──────────────────────────────┼───────────────────────────────────┘
///                                     │
///      ┌──────────────────────────────▼───────────────────────────────────┐
///      │                    CryptoRegistry.sol                            │
///      │                                                                  │
///      │   ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐   │
///      │   │ PvmVerifier  │  │  PvmBlake2   │  │   Nonce Manager    │   │
///      │   │  (library)   │  │  (library)   │  │   (replay prot)    │   │
///      │   └──────┬───────┘  └──────┬───────┘  └────────┬───────────┘   │
///      │          │                 │                    │               │
///      │   ┌──────▼─────────────────▼────────────────────▼───────────┐  │
///      │   │              Unified Crypto API                         │  │
///      │   │  verifySr25519 · verifyEd25519 · blake2b256            │  │
///      │   │  bn128Mul · pedersenCommit · computeStealthAddress     │  │
///      │   │  verifyXcmMessageAuth · consumeSubstrateAuth           │  │
///      │   └─────────────────────────────────────────────────────────┘  │
///      └──────────────────────────────────────────────────────────────────┘
///               │                    │
///      ┌────────▼──────┐    ┌───────▼────────┐
///      │StealthPayment │    │   XcmRouter    │
///      │ (substrate    │    │ (signed XCM    │
///      │  auth, stealth│    │  confirmations)│
///      │  derivation)  │    │                │
///      └───────────────┘    └────────────────┘
///
///      Key innovation: Sr25519 (Schnorr on Ristretto255) CANNOT be implemented
///      in pure Solidity. The Ristretto255 curve has no EVM precompile equivalent.
///      Only through the PVM's native Rust schnorrkel crate can these signatures
///      be verified, enabling native Polkadot wallet integration with EVM contracts.
contract CryptoRegistry is ICryptoRegistry, Ownable2Step, Pausable, ReentrancyGuard {
    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice Precompile availability flags (auto-detected in constructor)
    bool public override sr25519Available;
    bool public override ed25519Available;
    bool public override blake2fAvailable;
    bool public override bn128Available;

    /// @notice XCM dispatch precompile availability (TRACK 2)
    /// @dev When true, native XCM message dispatch is available from EVM
    bool public xcmDispatchAvailable;

    /// @notice Nonce tracking for substrate auth replay protection
    /// @dev Maps keccak256(pubkey) => next expected nonce
    mapping(bytes32 pubkeyHash => uint256 nonce) private _substrateNonces;

    /// @notice Total signature verifications processed (for monitoring)
    uint256 public totalVerifications;

    /// @notice Total Blake2b hashes computed
    uint256 public totalBlake2bHashes;

    /// @notice Authorized contracts that can consume substrate auth nonces
    mapping(address => bool) public isAuthorizedConsumer;

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor() Ownable(msg.sender) {
        _detectPrecompiles();
    }

    // =========================================================================
    // External — Signature Verification
    // =========================================================================

    /// @inheritdoc ICryptoRegistry
    function verifySr25519Signature(
        bytes32 pubkey,
        bytes calldata signature,
        bytes calldata message
    ) external view override returns (bool valid) {
        if (pubkey == bytes32(0)) return false;
        if (signature.length != 64) return false;

        // If precompile is available, call it
        if (sr25519Available) {
            valid = PvmVerifier.verifySr25519(pubkey, bytes(signature), bytes(message));
        }
        // If not available, return false (caller should handle fallback)
    }

    /// @inheritdoc ICryptoRegistry
    function verifyEd25519Signature(
        bytes32 pubkey,
        bytes32 sigR,
        bytes32 sigS,
        bytes calldata message
    ) external view override returns (bool valid) {
        if (pubkey == bytes32(0)) return false;

        if (ed25519Available) {
            valid = PvmVerifier.verifyEd25519(pubkey, sigR, sigS, bytes(message));
        }
    }

    /// @inheritdoc ICryptoRegistry
    function batchVerifySr25519(
        bytes32[] calldata pubkeys,
        bytes[] calldata signatures,
        bytes[] calldata messages
    ) external view override returns (bool[] memory results) {
        uint256 len = pubkeys.length;
        if (len != signatures.length || len != messages.length) revert BatchLengthMismatch();

        results = new bool[](len);

        if (!sr25519Available) return results; // All false

        for (uint256 i = 0; i < len;) {
            if (pubkeys[i] != bytes32(0) && signatures[i].length == 64) {
                results[i] = PvmVerifier.verifySr25519(
                    pubkeys[i],
                    bytes(signatures[i]),
                    bytes(messages[i])
                );
            }
            unchecked { i++; }
        }
    }

    // =========================================================================
    // External — Blake2b Hashing
    // =========================================================================

    /// @inheritdoc ICryptoRegistry
    function blake2b256(bytes calldata data) external view override returns (bytes32 hash) {
        if (!blake2fAvailable) revert Blake2fNotAvailable();
        hash = PvmBlake2.blake2b256(bytes(data));
    }

    /// @inheritdoc ICryptoRegistry
    function blake2b256Keyed(bytes calldata key, bytes calldata data) external view override returns (bytes32 hash) {
        if (!blake2fAvailable) revert Blake2fNotAvailable();
        hash = PvmBlake2.blake2b256Keyed(bytes(key), bytes(data));
    }

    // =========================================================================
    // External — Substrate-Specific Blake2b Functions (TRACK 2)
    // =========================================================================

    /// @inheritdoc ICryptoRegistry
    /// @dev TRACK 2: Substrate uses 128-bit Blake2b for storage map keys
    function blake2b128(bytes calldata data) external view override returns (bytes16 hash) {
        if (!blake2fAvailable) revert Blake2fNotAvailable();
        hash = PvmBlake2.blake2b128(bytes(data));
    }

    /// @inheritdoc ICryptoRegistry
    /// @dev TRACK 2: Computes Substrate AccountId32 = Blake2b-256(pubkey)
    ///      This is what gets encoded as SS58 address in Polkadot wallets.
    function computeSubstrateAccountId(bytes32 pubkey) external view override returns (bytes32 accountId) {
        if (!blake2fAvailable) revert Blake2fNotAvailable();
        if (pubkey == bytes32(0)) revert InvalidPublicKey();
        accountId = PvmBlake2.computeSubstrateAccountId(pubkey);
    }

    /// @inheritdoc ICryptoRegistry
    /// @dev TRACK 2: Computes Blake2_128Concat storage key format used by Substrate
    function blake2b128Concat(bytes calldata key) external view override returns (bytes memory storageKey) {
        if (!blake2fAvailable) revert Blake2fNotAvailable();
        storageKey = PvmBlake2.blake2b128Concat(bytes(key));
    }

    /// @inheritdoc ICryptoRegistry
    /// @dev TRACK 2: Hash XCM message exactly as Substrate does
    function hashXcmMessage(
        uint8 xcmVersion,
        bytes calldata instructions
    ) external view override returns (bytes32 hash) {
        if (!blake2fAvailable) revert Blake2fNotAvailable();
        hash = PvmBlake2.hashXcmMessage(xcmVersion, bytes(instructions));
    }

    /// @inheritdoc ICryptoRegistry
    /// @dev TRACK 2: Merkle node hashing for state proof verification
    function hashMerkleNode(bytes32 left, bytes32 right) external view override returns (bytes32 nodeHash) {
        if (!blake2fAvailable) revert Blake2fNotAvailable();
        nodeHash = PvmBlake2.hashMerkleNode(left, right);
    }

    // =========================================================================
    // External — BN128 Curve Operations
    // =========================================================================

    /// @inheritdoc ICryptoRegistry
    function bn128ScalarMul(
        uint256 px,
        uint256 py,
        uint256 scalar
    ) external view override returns (uint256 x, uint256 y) {
        (x, y) = PvmVerifier.bn128Mul(px, py, scalar);
    }

    /// @inheritdoc ICryptoRegistry
    function bn128PointAdd(
        uint256 x1,
        uint256 y1,
        uint256 x2,
        uint256 y2
    ) external view override returns (uint256 x, uint256 y) {
        (x, y) = PvmVerifier.bn128Add(x1, y1, x2, y2);
    }

    /// @inheritdoc ICryptoRegistry
    function computePedersenCommitment(
        uint256 value,
        uint256 blindingFactor,
        uint256 hx,
        uint256 hy
    ) external view override returns (uint256 cx, uint256 cy) {
        (cx, cy) = PvmVerifier.pedersenCommit(value, blindingFactor, hx, hy);
    }

    // =========================================================================
    // External — Stealth Address Integration
    // =========================================================================

    /// @inheritdoc ICryptoRegistry
    function computeStealthAddress(
        bytes32 spendingPubKey,
        bytes32 sharedSecretHash
    ) external pure override returns (address) {
        return _deriveStealthAddress(spendingPubKey, sharedSecretHash);
    }

    /// @inheritdoc ICryptoRegistry
    function verifyStealthDerivation(
        bytes32 spendingPubKey,
        bytes32 sharedSecretHash,
        address expectedStealthAddress
    ) external pure override returns (bool valid) {
        valid = _deriveStealthAddress(spendingPubKey, sharedSecretHash) == expectedStealthAddress;
    }

    // =========================================================================
    // External — XCM Message Authentication
    // =========================================================================

    /// @inheritdoc ICryptoRegistry
    function computeBlake2bXcmHash(
        uint256 routeId,
        uint32 paraId,
        uint256 amount,
        bytes32 beneficiary,
        uint256 nonce
    ) external view override returns (bytes32) {
        if (!blake2fAvailable) revert Blake2fNotAvailable();

        bytes memory payload = abi.encodePacked(
            "OmniShield::XCM::v2::blake2b",
            routeId,
            paraId,
            amount,
            beneficiary,
            nonce
        );
        return PvmBlake2.blake2b256(payload);
    }

    /// @inheritdoc ICryptoRegistry
    function verifyXcmMessageAuth(
        bytes32 messageHash,
        bytes32 pubkey,
        bytes calldata signature
    ) external view override returns (bool valid) {
        if (pubkey == bytes32(0)) return false;

        // Try sr25519 first (primary Polkadot scheme)
        if (sr25519Available && signature.length == 64) {
            bytes memory hashMsg = abi.encodePacked(messageHash);
            valid = PvmVerifier.verifySr25519(pubkey, bytes(signature), hashMsg);
            if (valid) return true;
        }

        // Fallback to ed25519 if sr25519 fails
        if (ed25519Available && signature.length == 64) {
            bytes32 sigR = bytes32(signature[0:32]);
            bytes32 sigS = bytes32(signature[32:64]);
            bytes memory hashMsg = abi.encodePacked(messageHash);
            valid = PvmVerifier.verifyEd25519(pubkey, sigR, sigS, hashMsg);
        }
    }

    // =========================================================================
    // External — Substrate Auth (Nonce Management)
    // =========================================================================

    /// @inheritdoc ICryptoRegistry
    function getSubstrateNonce(bytes32 pubkeyHash) external view override returns (uint256) {
        return _substrateNonces[pubkeyHash];
    }

    /// @inheritdoc ICryptoRegistry
    function consumeSubstrateAuth(
        bytes32 pubkey,
        bytes calldata signature,
        bytes calldata message,
        uint256 expectedNonce
    ) external override nonReentrant returns (bool valid) {
        if (!isAuthorizedConsumer[msg.sender] && msg.sender != owner()) revert SignatureVerificationFailed();

        bytes32 pubkeyHash = keccak256(abi.encode(pubkey));

        // Verify nonce
        if (_substrateNonces[pubkeyHash] != expectedNonce) revert NonceAlreadyUsed();

        // Verify signature (try sr25519 first, then ed25519)
        if (sr25519Available && signature.length == 64) {
            valid = PvmVerifier.verifySr25519(pubkey, bytes(signature), bytes(message));
        }
        if (!valid && ed25519Available && signature.length == 64) {
            bytes32 sigR = bytes32(signature[0:32]);
            bytes32 sigS = bytes32(signature[32:64]);
            valid = PvmVerifier.verifyEd25519(pubkey, sigR, sigS, bytes(message));
        }

        if (!valid) revert SignatureVerificationFailed();

        // Consume nonce
        _substrateNonces[pubkeyHash] = expectedNonce + 1;
        unchecked { totalVerifications++; }

        emit SubstrateNonceConsumed(pubkeyHash, expectedNonce);
    }

    // =========================================================================
    // External — Admin
    // =========================================================================

    /// @notice Authorize a contract to consume substrate auth nonces
    /// @param consumer Contract address to authorize (e.g., StealthPayment)
    function authorizeConsumer(address consumer) external onlyOwner {
        require(consumer != address(0), "Invalid consumer");
        isAuthorizedConsumer[consumer] = true;
    }

    /// @notice Revoke a consumer's authorization
    function revokeConsumer(address consumer) external onlyOwner {
        isAuthorizedConsumer[consumer] = false;
    }

    /// @notice Refresh precompile availability detection
    /// @dev Call after chain upgrades that may add/remove precompiles
    function refreshPrecompileStatus() external onlyOwner {
        _detectPrecompiles();
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // =========================================================================
    // External — Views
    // =========================================================================

    /// @inheritdoc ICryptoRegistry
    function getPrecompileStatus() external view override returns (PrecompileStatus memory) {
        return PrecompileStatus({
            sr25519: sr25519Available,
            ed25519: ed25519Available,
            blake2f: blake2fAvailable,
            bn128: bn128Available
        });
    }

    // =========================================================================
    // External — Polkadot Feature Status (TRACK 2)
    // =========================================================================

    /// @notice Get comprehensive Polkadot precompile feature status
    /// @dev Returns detailed status for all Track 2 relevant precompiles:
    ///      - NotAvailable: Precompile not deployed
    ///      - Available: Precompile deployed and working
    ///      - CodeReady: Our code is ready, awaiting precompile deployment
    ///      - Deprecated: Should not be used
    /// @return sr25519Status Sr25519 verification status
    /// @return ed25519Status Ed25519 verification status
    /// @return xcmStatus XCM dispatch status
    /// @return assetsStatus Native assets precompile status
    function getPolkadotFeatureStatus() external view returns (
        uint8 sr25519Status,
        uint8 ed25519Status,
        uint8 xcmStatus,
        uint8 assetsStatus
    ) {
        (
            PrecompileFeatureStatus sr25519,
            PrecompileFeatureStatus ed25519,
            PrecompileFeatureStatus xcm,
            PrecompileFeatureStatus assets
        ) = PolkadotFeatures.getFeatureStatus();
        return (uint8(sr25519), uint8(ed25519), uint8(xcm), uint8(assets));
    }

    /// @notice Check if XCM dispatch precompile is available
    /// @dev When true, XcmRouter can dispatch native XCM messages
    function isXcmDispatchAvailable() external view returns (bool) {
        return xcmDispatchAvailable;
    }

    /// @notice Get the precompile address constants (for frontend/debugging)
    /// @return sr25519Addr Sr25519 precompile address (0x0403)
    /// @return ed25519Addr Ed25519 precompile address (0x0402)
    /// @return xcmAddr XCM dispatch precompile address (0x0816)
    /// @return assetsAddr Native assets precompile address (0x0806)
    function getPrecompileAddresses() external pure returns (
        address sr25519Addr,
        address ed25519Addr,
        address xcmAddr,
        address assetsAddr
    ) {
        sr25519Addr = PolkadotPrecompileAddresses.SR25519_VERIFY;
        ed25519Addr = PolkadotPrecompileAddresses.ED25519_VERIFY;
        xcmAddr = PolkadotPrecompileAddresses.XCM_DISPATCH;
        assetsAddr = PolkadotPrecompileAddresses.ASSETS;
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    /// @notice Auto-detect all PVM precompile availability
    /// @dev Called in constructor and by refreshPrecompileStatus().
    ///      Standard EVM precompiles (Blake2f, BN128) are tested via actual calls.
    ///      Substrate precompiles (Sr25519, Ed25519, XCM) are tested via extcodesize.
    function _detectPrecompiles() internal {
        // Substrate-specific precompiles: test via extcodesize
        sr25519Available = PvmVerifier.isSr25519Available();
        ed25519Available = PvmVerifier.isEd25519Available();
        xcmDispatchAvailable = PvmVerifier.isXcmDispatchAvailable();

        // Standard EVM precompiles: test via actual call
        blake2fAvailable = PvmBlake2.isAvailable();
        bn128Available = PvmVerifier.isBn128Available();

        emit PrecompileDetected("sr25519", PvmVerifier.SR25519_VERIFY, sr25519Available);
        emit PrecompileDetected("ed25519", PvmVerifier.ED25519_VERIFY, ed25519Available);
        emit PrecompileDetected("xcm_dispatch", PvmVerifier.XCM_DISPATCH, xcmDispatchAvailable);
        emit PrecompileDetected("blake2f", address(9), blake2fAvailable);
        emit PrecompileDetected("bn128", address(7), bn128Available);
    }

    /// @notice Derive a stealth address from spending public key + shared secret hash
    /// @dev stealthAddr = address(keccak256(spendingPubKey || sharedSecretHash))
    ///      This matches the EIP-5564 derivation pattern adapted for OmniShield:
    ///        1. Sender computes ECDH shared secret with recipient's viewing key
    ///        2. Sender hashes shared secret to get sharedSecretHash
    ///        3. Stealth address = truncated hash of (spendingPubKey || sharedSecretHash)
    ///        4. Recipient can reconstruct by computing same ECDH shared secret
    function _deriveStealthAddress(
        bytes32 spendingPubKey,
        bytes32 sharedSecretHash
    ) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            "OmniShield::Stealth::v1",
            spendingPubKey,
            sharedSecretHash
        )))));
    }
}
