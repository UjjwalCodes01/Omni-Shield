// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPvmPrecompiles
/// @author Omni-Shield Team
/// @notice Interface definitions for PVM (Polkadot Virtual Machine) precompiled contracts
/// @dev These precompiles expose native Rust cryptographic libraries to Solidity contracts.
///      On Polkadot Hub, the PVM runtime compiles these from production Rust crates:
///
///        Precompile          | Address | Rust Crate
///        --------------------|---------|--------------------
///        Blake2f (EIP-152)   | 0x0009  | blake2b_simd
///        BN128 ecAdd         | 0x0006  | substrate-bn (EIP-196)
///        BN128 ecMul         | 0x0007  | substrate-bn (EIP-196)
///        BN128 ecPairing     | 0x0008  | substrate-bn (EIP-197)
///        Ed25519 Verify      | 0x0402  | ed25519-dalek
///        Sr25519 Verify      | 0x0403  | schnorrkel
///        XCM Dispatch        | 0x0816  | pallet-xcm (see IXcmPrecompile.sol)
///
///      Standard EVM precompiles (0x0001–0x0009) are built into the execution engine.
///      Substrate-specific precompiles (0x0402, 0x0403) are deployed by the runtime
///      and can be detected via extcodesize.
///
///      On testnet, substrate-specific precompiles may not be deployed.
///      The CryptoRegistry contract handles graceful fallback in all cases.

/// @title IEd25519Verify
/// @notice Precompile interface for Ed25519 signature verification
/// @dev Wraps the ed25519-dalek Rust crate compiled into the PVM runtime.
///      Ed25519 is used by some Polkadot validators and is the standard
///      signature scheme in many blockchain ecosystems (Solana, NEAR, etc.)
///
///      Precompile address: 0x0000000000000000000000000000000000000402
///
///      Calling convention (raw bytes):
///        Input:
///          [0..31]   Signature R component (32 bytes)
///          [32..63]  Signature S component (32 bytes)
///          [64..95]  Public key (32 bytes)
///          [96..]    Message (variable length)
///        Output:
///          [0..31]   uint256: 1 = valid, 0 = invalid
interface IEd25519Verify {
    /// @notice Verify an Ed25519 signature
    /// @param sigR Signature R component (32 bytes, compressed Edwards point)
    /// @param sigS Signature S component (32 bytes, scalar)
    /// @param pubkey Ed25519 public key (32 bytes, compressed Edwards point)
    /// @param message The signed message bytes
    /// @return valid True if signature is valid for the given public key and message
    function verify(
        bytes32 sigR,
        bytes32 sigS,
        bytes32 pubkey,
        bytes calldata message
    ) external view returns (bool valid);
}

/// @title ISr25519Verify
/// @notice Precompile interface for Sr25519 signature verification (Polkadot native)
/// @dev Wraps the schnorrkel Rust crate compiled into the PVM runtime.
///      Sr25519 uses Schnorr signatures on the Ristretto255 curve. This is the
///      PRIMARY signing scheme in the Polkadot ecosystem — ALL Substrate accounts
///      (Polkadot.js, Talisman, SubWallet) use sr25519 by default.
///
///      This precompile is ESSENTIAL because Ristretto255/Schnorr CANNOT be
///      implemented in pure Solidity — the curve operations are fundamentally
///      different from secp256k1/BN128. The only path is through native Rust.
///
///      Precompile address: 0x0000000000000000000000000000000000000403
///
///      Calling convention (raw bytes):
///        Input:
///          [0..31]   Public key (32 bytes, compressed Ristretto point)
///          [32..95]  Signature (64 bytes: R || S)
///          [96..]    Message (variable length)
///        Output:
///          [0..31]   uint256: 1 = valid, 0 = invalid
interface ISr25519Verify {
    /// @notice Verify an Sr25519 (Schnorr/Ristretto) signature
    /// @param pubkey Sr25519 public key (32 bytes, compressed Ristretto255 point)
    /// @param signature Sr25519 signature (64 bytes: R component || S scalar)
    /// @param message The signed message bytes
    /// @return valid True if signature is valid for the given public key and message
    function verify(
        bytes32 pubkey,
        bytes calldata signature,
        bytes calldata message
    ) external view returns (bool valid);
}
