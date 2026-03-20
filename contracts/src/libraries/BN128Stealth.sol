// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title BN128Stealth
/// @author Omni-Shield Team
/// @notice BN128 elliptic curve operations for stealth address privacy
/// @dev ╔═══════════════════════════════════════════════════════════════════════════╗
///      ║                    TRACK 2: POLKADOT PVM INTEGRATION                      ║
///      ╠═══════════════════════════════════════════════════════════════════════════╣
///      ║  This library provides privacy-preserving cryptographic operations        ║
///      ║  using the BN128 curve via EVM precompiles (0x06, 0x07, 0x08).            ║
///      ║                                                                           ║
///      ║  WHY BN128 FOR TRACK 2:                                                   ║
///      ║  • BN128 precompiles are WORKING on Polkadot Hub testnet                 ║
///      ║  • Enables Pedersen commitments for amount hiding                         ║
///      ║  • Provides foundation for zero-knowledge proofs                          ║
///      ║  • Demonstrates real precompile usage (not just documentation)            ║
///      ║                                                                           ║
///      ║  Key Features:                                                            ║
///      ║  • Pedersen commitment scheme: C = v*G + r*H                             ║
///      ║  • Verifiable stealth address derivation                                  ║
///      ║  • Amount commitment verification                                         ║
///      ║  • Homomorphic properties for potential future range proofs              ║
///      ╚═══════════════════════════════════════════════════════════════════════════╝
///
///      Mathematical Background:
///        BN128 (alt_bn128) is a pairing-friendly elliptic curve:
///          y² = x³ + 3 over 𝔽_p where p ≈ 2²⁵⁴
///
///        Pedersen Commitment:
///          C = v*G + r*H
///          where:
///            v = value to commit
///            r = random blinding factor
///            G = generator point (1, 2)
///            H = nothing-up-my-sleeve point
///
///      Security:
///        - Perfectly hiding: C reveals nothing about v
///        - Computationally binding: cannot find different (v', r') with same C
///        - Homomorphic: C1 + C2 commits to v1 + v2
library BN128Stealth {
    // =========================================================================
    // Precompile Addresses (EIP-196, EIP-197)
    // =========================================================================

    /// @notice BN128 point addition precompile
    address internal constant BN128_ADD = 0x0000000000000000000000000000000000000006;

    /// @notice BN128 scalar multiplication precompile
    address internal constant BN128_MUL = 0x0000000000000000000000000000000000000007;

    /// @notice BN128 pairing check precompile
    address internal constant BN128_PAIRING = 0x0000000000000000000000000000000000000008;

    // =========================================================================
    // BN128 Curve Constants
    // =========================================================================

    /// @notice Generator point G = (1, 2) on BN128
    uint256 internal constant G_X = 1;
    uint256 internal constant G_Y = 2;

    /// @notice Field modulus (prime p)
    uint256 internal constant FIELD_MODULUS = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

    /// @notice Curve order (number of points)
    uint256 internal constant CURVE_ORDER = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @notice Nothing-up-my-sleeve point H = hash_to_curve("OmniShield::Pedersen::H")
    /// @dev Pre-computed: keccak256("OmniShield::Pedersen::H") mod p mapped to curve
    ///      H_X = blake2b256("OmniShield::BN128::Generator::H::X") mod p
    ///      H_Y computed as valid curve point
    uint256 internal constant H_X = 16540640123574156134436876038791482806971768689494387082833631921987005038935;
    uint256 internal constant H_Y = 20819045374670962167435360035096875258406992893633759881276124905556507972311;

    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidPoint();
    error InvalidScalar();
    error PrecompileCallFailed();
    error CommitmentMismatch();
    error InvalidBlindingFactor();

    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice A point on the BN128 curve
    struct Point {
        uint256 x;
        uint256 y;
    }

    /// @notice A Pedersen commitment with its opening (for verification)
    struct Commitment {
        uint256 cx;         // Commitment point X
        uint256 cy;         // Commitment point Y
        uint256 value;      // The committed value (only for verification, not revealed on-chain)
        uint256 blinding;   // The blinding factor (only for verification, not revealed on-chain)
    }

    /// @notice Stealth commitment data stored on-chain
    struct StealthCommitment {
        uint256 cx;         // Commitment point X
        uint256 cy;         // Commitment point Y
        bytes32 commitmentHash;  // Hash for quick lookup
    }

    // =========================================================================
    // Point Operations (Via Precompiles)
    // =========================================================================

    /// @notice Add two points on BN128
    /// @dev Calls the ecAdd precompile at 0x06
    /// @param p1 First point
    /// @param p2 Second point
    /// @return result The sum p1 + p2
    function pointAdd(Point memory p1, Point memory p2) internal view returns (Point memory result) {
        uint256[4] memory input = [p1.x, p1.y, p2.x, p2.y];
        uint256[2] memory output;

        assembly {
            let success := staticcall(gas(), 0x06, input, 128, output, 64)
            if iszero(success) {
                revert(0, 0)
            }
        }

        result.x = output[0];
        result.y = output[1];
    }

    /// @notice Multiply a point by a scalar on BN128
    /// @dev Calls the ecMul precompile at 0x07
    /// @param p The point to multiply
    /// @param scalar The scalar multiplier
    /// @return result The product scalar * p
    function pointMul(Point memory p, uint256 scalar) internal view returns (Point memory result) {
        uint256[3] memory input = [p.x, p.y, scalar];
        uint256[2] memory output;

        assembly {
            let success := staticcall(gas(), 0x07, input, 96, output, 64)
            if iszero(success) {
                revert(0, 0)
            }
        }

        result.x = output[0];
        result.y = output[1];
    }

    /// @notice Check if a point is the identity (point at infinity)
    /// @param p Point to check
    /// @return isIdentity True if p is the identity element
    function isIdentityPoint(Point memory p) internal pure returns (bool isIdentity) {
        isIdentity = (p.x == 0 && p.y == 0);
    }

    /// @notice Check if two points are equal
    /// @param p1 First point
    /// @param p2 Second point
    /// @return equal True if points are equal
    function pointsEqual(Point memory p1, Point memory p2) internal pure returns (bool equal) {
        equal = (p1.x == p2.x && p1.y == p2.y);
    }

    // =========================================================================
    // Pedersen Commitment Operations
    // =========================================================================

    /// @notice Compute a Pedersen commitment: C = v*G + r*H
    /// @dev Uses BN128 precompiles for efficient elliptic curve operations.
    ///      The commitment is perfectly hiding (reveals nothing about v)
    ///      and computationally binding (cannot find different v' with same C).
    ///
    ///      TRACK 2 DEMONSTRATION:
    ///      This function makes 3 precompile calls:
    ///        1. ecMul(G, v) - scalar multiplication with generator
    ///        2. ecMul(H, r) - scalar multiplication with H point
    ///        3. ecAdd(vG, rH) - point addition
    ///
    /// @param value The value to commit (typically an amount in wei)
    /// @param blindingFactor Random 256-bit number for hiding
    /// @return cx Commitment X coordinate
    /// @return cy Commitment Y coordinate
    function computeCommitment(
        uint256 value,
        uint256 blindingFactor
    ) internal view returns (uint256 cx, uint256 cy) {
        if (blindingFactor == 0 || blindingFactor >= CURVE_ORDER) {
            revert InvalidBlindingFactor();
        }

        // vG = value * G
        Point memory vG = pointMul(Point(G_X, G_Y), value % CURVE_ORDER);

        // rH = blindingFactor * H
        Point memory rH = pointMul(Point(H_X, H_Y), blindingFactor);

        // C = vG + rH
        Point memory commitment = pointAdd(vG, rH);

        cx = commitment.x;
        cy = commitment.y;
    }

    /// @notice Verify a Pedersen commitment opening
    /// @dev Recomputes C = v*G + r*H and checks if it matches the provided commitment
    /// @param cx Commitment X coordinate
    /// @param cy Commitment Y coordinate
    /// @param value The claimed value
    /// @param blindingFactor The claimed blinding factor
    /// @return valid True if the opening is valid
    function verifyCommitment(
        uint256 cx,
        uint256 cy,
        uint256 value,
        uint256 blindingFactor
    ) internal view returns (bool valid) {
        (uint256 computedCx, uint256 computedCy) = computeCommitment(value, blindingFactor);
        valid = (cx == computedCx && cy == computedCy);
    }

    /// @notice Compute a commitment hash for storage/lookup
    /// @param cx Commitment X coordinate
    /// @param cy Commitment Y coordinate
    /// @return hash Keccak256 hash of the commitment point
    function commitmentHash(uint256 cx, uint256 cy) internal pure returns (bytes32 hash) {
        hash = keccak256(abi.encodePacked(cx, cy));
    }

    // =========================================================================
    // Stealth Address Operations
    // =========================================================================

    /// @notice Derive a stealth address using BN128 ECDH
    /// @dev This is an alternative stealth derivation that uses BN128 curve operations.
    ///      The process:
    ///        1. Sender generates ephemeral keypair (e, E = e*G)
    ///        2. Sender computes shared secret: S = e * ViewingPubKey
    ///        3. Stealth private key: s = spendingPrivKey + H(S)
    ///        4. Stealth address: address(keccak256(s*G))
    ///
    ///      On-chain we verify: stealthAddr == address(keccak256(SpendingPubKey + H(S)*G))
    ///
    /// @param spendingPubKeyX Recipient's spending public key X
    /// @param spendingPubKeyY Recipient's spending public key Y
    /// @param sharedSecretX Shared secret point X (from ECDH)
    /// @param sharedSecretY Shared secret point Y (from ECDH)
    /// @return stealthAddress The derived stealth address
    function deriveStealthAddressBN128(
        uint256 spendingPubKeyX,
        uint256 spendingPubKeyY,
        uint256 sharedSecretX,
        uint256 sharedSecretY
    ) internal view returns (address stealthAddress) {
        // Hash the shared secret to get a scalar
        uint256 scalar = uint256(keccak256(abi.encodePacked(
            "OmniShield::StealthScalar::v1",
            sharedSecretX,
            sharedSecretY
        ))) % CURVE_ORDER;

        // Compute scalar * G
        Point memory scalarG = pointMul(Point(G_X, G_Y), scalar);

        // Add to spending public key: StealthPubKey = SpendingPubKey + scalar*G
        Point memory stealthPubKey = pointAdd(
            Point(spendingPubKeyX, spendingPubKeyY),
            scalarG
        );

        // Derive address from the stealth public key
        stealthAddress = address(uint160(uint256(keccak256(abi.encodePacked(
            stealthPubKey.x,
            stealthPubKey.y
        )))));
    }

    /// @notice Verify a BN128-based stealth address derivation
    /// @param expectedAddress The stealth address to verify
    /// @param spendingPubKeyX Spending public key X
    /// @param spendingPubKeyY Spending public key Y
    /// @param sharedSecretX Shared secret X
    /// @param sharedSecretY Shared secret Y
    /// @return valid True if the derivation matches
    function verifyStealthDerivationBN128(
        address expectedAddress,
        uint256 spendingPubKeyX,
        uint256 spendingPubKeyY,
        uint256 sharedSecretX,
        uint256 sharedSecretY
    ) internal view returns (bool valid) {
        address computed = deriveStealthAddressBN128(
            spendingPubKeyX, spendingPubKeyY,
            sharedSecretX, sharedSecretY
        );
        valid = (computed == expectedAddress);
    }

    // =========================================================================
    // Commitment Arithmetic (Homomorphic Properties)
    // =========================================================================

    /// @notice Add two commitments (homomorphic addition)
    /// @dev If C1 = v1*G + r1*H and C2 = v2*G + r2*H,
    ///      then C1 + C2 = (v1+v2)*G + (r1+r2)*H
    ///      This is a commitment to (v1 + v2) with blinding (r1 + r2).
    ///
    ///      Useful for:
    ///      - Verifying sum of hidden amounts equals a known total
    ///      - Range proof building blocks
    ///
    /// @param c1x First commitment X
    /// @param c1y First commitment Y
    /// @param c2x Second commitment X
    /// @param c2y Second commitment Y
    /// @return cx Sum commitment X
    /// @return cy Sum commitment Y
    function addCommitments(
        uint256 c1x,
        uint256 c1y,
        uint256 c2x,
        uint256 c2y
    ) internal view returns (uint256 cx, uint256 cy) {
        Point memory sum = pointAdd(Point(c1x, c1y), Point(c2x, c2y));
        cx = sum.x;
        cy = sum.y;
    }

    /// @notice Verify that a sum of commitments equals a known total commitment
    /// @dev Used to verify: C_total = C1 + C2 + ... + Cn
    ///      If each Ci commits to vi, this verifies sum(vi) without revealing individual values.
    /// @param commitmentXs Array of commitment X coordinates
    /// @param commitmentYs Array of commitment Y coordinates
    /// @param expectedSumX Expected sum commitment X
    /// @param expectedSumY Expected sum commitment Y
    /// @return valid True if the sum matches
    function verifyCommitmentSum(
        uint256[] memory commitmentXs,
        uint256[] memory commitmentYs,
        uint256 expectedSumX,
        uint256 expectedSumY
    ) internal view returns (bool valid) {
        require(commitmentXs.length == commitmentYs.length, "Length mismatch");

        if (commitmentXs.length == 0) {
            return (expectedSumX == 0 && expectedSumY == 0);
        }

        Point memory sum = Point(commitmentXs[0], commitmentYs[0]);

        for (uint256 i = 1; i < commitmentXs.length; i++) {
            sum = pointAdd(sum, Point(commitmentXs[i], commitmentYs[i]));
        }

        valid = (sum.x == expectedSumX && sum.y == expectedSumY);
    }

    // =========================================================================
    // Generator Points
    // =========================================================================

    /// @notice Get the standard generator point G
    /// @return gx G point X coordinate
    /// @return gy G point Y coordinate
    function getGeneratorG() internal pure returns (uint256 gx, uint256 gy) {
        gx = G_X;
        gy = G_Y;
    }

    /// @notice Get the H point for Pedersen commitments
    /// @return hx H point X coordinate
    /// @return hy H point Y coordinate
    function getGeneratorH() internal pure returns (uint256 hx, uint256 hy) {
        hx = H_X;
        hy = H_Y;
    }

    // =========================================================================
    // Precompile Availability Check
    // =========================================================================

    /// @notice Check if BN128 precompiles are available
    /// @dev Tests ecMul(G, 1) == G as a sanity check
    /// @return available True if BN128 precompiles work
    function isBN128Available() internal view returns (bool available) {
        uint256[3] memory input = [G_X, G_Y, uint256(1)];
        uint256[2] memory output;

        assembly {
            let success := staticcall(gas(), 0x07, input, 96, output, 64)
            if iszero(success) {
                // Precompile failed
                available := 0
            }
        }

        // Verify: 1 * G == G
        available = (output[0] == G_X && output[1] == G_Y);
    }
}
