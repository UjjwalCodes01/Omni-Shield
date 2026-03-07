// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title PvmVerifier
/// @author Omni-Shield Team
/// @notice Library for cryptographic signature verification via PVM precompiles
/// @dev Provides low-level staticcall wrappers for Polkadot-native signature schemes
///      that are compiled from Rust cryptographic libraries into the PVM runtime:
///
///        - Sr25519 (schnorrkel crate): Schnorr signatures on Ristretto255 curve
///          This is Polkadot's PRIMARY signing scheme — impossible to implement
///          in pure Solidity due to the Ristretto255 curve operations.
///
///        - Ed25519 (ed25519-dalek crate): EdDSA on Curve25519
///          Used by some validators and cross-chain bridges.
///
///        - BN128 / alt_bn128 (substrate-bn): Elliptic curve operations
///          Standard EVM precompiles for ZK-SNARK verification and
///          stealth address Pedersen commitments.
///
///      All functions use low-level staticcall for gas efficiency and return
///      false (rather than revert) when verification fails or the precompile
///      is unavailable, enabling graceful fallback behavior.
library PvmVerifier {
    // =========================================================================
    // Precompile Addresses
    // =========================================================================

    /// @notice Ed25519 signature verification precompile (ed25519-dalek)
    /// @dev Frontier EVM standard address for Substrate Ed25519 verification.
    ///      Available when the pallet-evm runtime is configured with
    ///      Ed25519Verify in the PrecompilesValue set.
    address internal constant ED25519_VERIFY = 0x0000000000000000000000000000000000000402;

    /// @notice Sr25519 signature verification precompile (schnorrkel)
    /// @dev Frontier EVM address for Substrate Sr25519 verification.
    ///      This is the most important PVM precompile for Polkadot integration —
    ///      it enables native Substrate wallet signatures (Polkadot.js, Talisman,
    ///      SubWallet) to be verified on-chain in EVM contracts.
    address internal constant SR25519_VERIFY = 0x0000000000000000000000000000000000000403;

    /// @notice BN128 point addition precompile (EIP-196)
    address internal constant BN128_ADD = 0x0000000000000000000000000000000000000006;

    /// @notice BN128 scalar multiplication precompile (EIP-196)
    address internal constant BN128_MUL = 0x0000000000000000000000000000000000000007;

    /// @notice BN128 pairing check precompile (EIP-197)
    address internal constant BN128_PAIRING = 0x0000000000000000000000000000000000000008;

    // =========================================================================
    // BN128 Curve Constants
    // =========================================================================

    /// @notice BN128 generator point G = (1, 2)
    uint256 internal constant BN128_G_X = 1;
    uint256 internal constant BN128_G_Y = 2;

    /// @notice BN128 curve order
    uint256 internal constant BN128_ORDER = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    // =========================================================================
    // Sr25519 Verification
    // =========================================================================

    /// @notice Verify an sr25519 (Schnorr/Ristretto255) signature
    /// @dev Makes a low-level staticcall to the sr25519 precompile at 0x0403.
    ///      Returns false if the precompile is unavailable or signature is invalid.
    ///
    ///      Input encoding:
    ///        [0..31]   Public key (32 bytes, compressed Ristretto point)
    ///        [32..95]  Signature (64 bytes: R || S)
    ///        [96..]    Message (variable length)
    ///
    /// @param pubkey Sr25519 public key (32 bytes)
    /// @param signature Sr25519 signature (must be exactly 64 bytes)
    /// @param message The signed message
    /// @return valid True if signature verification succeeds
    function verifySr25519(
        bytes32 pubkey,
        bytes memory signature,
        bytes memory message
    ) internal view returns (bool valid) {
        if (signature.length != 64) return false;

        // Pack: pubkey (32) || signature (64) || message (variable)
        bytes memory input = abi.encodePacked(pubkey, signature, message);

        (bool success, bytes memory output) = SR25519_VERIFY.staticcall(input);

        if (!success || output.length < 32) return false;

        // Decode result: uint256, 1 = valid
        uint256 result;
        assembly {
            result := mload(add(output, 32))
        }
        valid = (result == 1);
    }

    // =========================================================================
    // Ed25519 Verification
    // =========================================================================

    /// @notice Verify an ed25519 (EdDSA/Curve25519) signature
    /// @dev Makes a low-level staticcall to the ed25519 precompile at 0x0402.
    ///      Returns false if the precompile is unavailable or signature is invalid.
    ///
    ///      Input encoding (matches Moonbeam/Frontier convention):
    ///        [0..31]   Signature R component (32 bytes)
    ///        [32..63]  Signature S component (32 bytes)
    ///        [64..95]  Public key (32 bytes)
    ///        [96..]    Message (variable length)
    ///
    /// @param pubkey Ed25519 public key (32 bytes)
    /// @param sigR Signature R component (compressed Edwards point)
    /// @param sigS Signature S component (scalar)
    /// @param message The signed message
    /// @return valid True if signature verification succeeds
    function verifyEd25519(
        bytes32 pubkey,
        bytes32 sigR,
        bytes32 sigS,
        bytes memory message
    ) internal view returns (bool valid) {
        // Pack: sigR (32) || sigS (32) || pubkey (32) || message (variable)
        bytes memory input = abi.encodePacked(sigR, sigS, pubkey, message);

        (bool success, bytes memory output) = ED25519_VERIFY.staticcall(input);

        if (!success || output.length < 32) return false;

        uint256 result;
        assembly {
            result := mload(add(output, 32))
        }
        valid = (result == 1);
    }

    // =========================================================================
    // BN128 Curve Operations
    // =========================================================================

    /// @notice BN128 elliptic curve point addition
    /// @dev Calls the ecAdd precompile at 0x06 (EIP-196).
    ///      Computes (x1, y1) + (x2, y2) on the alt_bn128 curve.
    ///      Used for Pedersen commitment operations in stealth addresses.
    /// @param x1 X coordinate of first point
    /// @param y1 Y coordinate of first point
    /// @param x2 X coordinate of second point
    /// @param y2 Y coordinate of second point
    /// @return x X coordinate of result
    /// @return y Y coordinate of result
    function bn128Add(
        uint256 x1,
        uint256 y1,
        uint256 x2,
        uint256 y2
    ) internal view returns (uint256 x, uint256 y) {
        uint256[4] memory input = [x1, y1, x2, y2];
        uint256[2] memory output;

        assembly {
            // staticcall(gas, address, argsOffset, argsSize, retOffset, retSize)
            let success := staticcall(gas(), 0x06, input, 128, output, 64)
            if iszero(success) { revert(0, 0) }
        }

        x = output[0];
        y = output[1];
    }

    /// @notice BN128 elliptic curve scalar multiplication
    /// @dev Calls the ecMul precompile at 0x07 (EIP-196).
    ///      Computes scalar * (px, py) on the alt_bn128 curve.
    ///      Critical for stealth address ECDH shared secret computation:
    ///        sharedPoint = ephemeralSecret * ViewingPubKey
    /// @param px X coordinate of the point
    /// @param py Y coordinate of the point
    /// @param scalar The scalar multiplier
    /// @return x X coordinate of result
    /// @return y Y coordinate of result
    function bn128Mul(
        uint256 px,
        uint256 py,
        uint256 scalar
    ) internal view returns (uint256 x, uint256 y) {
        uint256[3] memory input = [px, py, scalar];
        uint256[2] memory output;

        assembly {
            let success := staticcall(gas(), 0x07, input, 96, output, 64)
            if iszero(success) { revert(0, 0) }
        }

        x = output[0];
        y = output[1];
    }

    /// @notice BN128 pairing check (bilinear pairing)
    /// @dev Calls the ecPairing precompile at 0x08 (EIP-197).
    ///      Verifies: e(a1, b1) * e(a2, b2) * ... = 1
    ///      Used for ZK-SNARK verification and advanced commitment schemes.
    /// @param input Packed pairing pairs (each pair: G1 point [2 × 32 bytes] + G2 point [4 × 32 bytes])
    /// @return valid True if the pairing equation holds
    function bn128Pairing(bytes memory input) internal view returns (bool valid) {
        uint256 inputLen = input.length;
        require(inputLen % 192 == 0, "Invalid pairing input length");

        (bool success, bytes memory output) = BN128_PAIRING.staticcall(input);

        if (!success || output.length < 32) return false;

        uint256 result;
        assembly {
            result := mload(add(output, 32))
        }
        valid = (result == 1);
    }

    /// @notice Compute a Pedersen commitment on BN128
    /// @dev Commitment = value * G + blindingFactor * H
    ///      where G = (1, 2) is the standard generator and
    ///      H = hash_to_curve("OmniShield::Pedersen") is a nothing-up-my-sleeve point.
    ///      Uses ecMul + ecAdd precompiles for gas-efficient computation.
    /// @param value The committed value
    /// @param blindingFactor Random blinding scalar
    /// @param hx X coordinate of the second generator H
    /// @param hy Y coordinate of the second generator H
    /// @return cx Commitment X coordinate
    /// @return cy Commitment Y coordinate
    function pedersenCommit(
        uint256 value,
        uint256 blindingFactor,
        uint256 hx,
        uint256 hy
    ) internal view returns (uint256 cx, uint256 cy) {
        // vG = value * G
        (uint256 vgx, uint256 vgy) = bn128Mul(BN128_G_X, BN128_G_Y, value);

        // bH = blindingFactor * H
        (uint256 bhx, uint256 bhy) = bn128Mul(hx, hy, blindingFactor);

        // C = vG + bH
        (cx, cy) = bn128Add(vgx, vgy, bhx, bhy);
    }

    // =========================================================================
    // Precompile Detection
    // =========================================================================

    /// @notice Check if the sr25519 precompile is available
    /// @dev Uses extcodesize — substrate-specific precompiles have deployed code
    ///      when configured in the runtime's PrecompilesValue set.
    function isSr25519Available() internal view returns (bool) {
        return _hasCode(SR25519_VERIFY);
    }

    /// @notice Check if the ed25519 precompile is available
    function isEd25519Available() internal view returns (bool) {
        return _hasCode(ED25519_VERIFY);
    }

    /// @notice Check if BN128 precompiles are available
    /// @dev Standard EVM precompiles (no bytecode), so we test via actual call.
    ///      Tests ecMul(G, 1) == G as a sanity check.
    function isBn128Available() internal view returns (bool) {
        uint256[3] memory input = [BN128_G_X, BN128_G_Y, uint256(1)];
        uint256[2] memory output;

        assembly {
            let success := staticcall(gas(), 0x07, input, 96, output, 64)
            if iszero(success) { return(0, 0) }
        }

        return output[0] == BN128_G_X && output[1] == BN128_G_Y;
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// @notice Check if an address has deployed bytecode
    /// @dev Works for substrate-specific precompiles (0x0402, 0x0403)
    ///      but NOT for standard EVM precompiles (0x01-0x09) which have no code.
    function _hasCode(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
}
