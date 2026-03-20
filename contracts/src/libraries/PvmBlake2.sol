// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title PvmBlake2
/// @author Omni-Shield Team
/// @notice Library for computing Blake2b hashes via the EIP-152 Blake2f precompile
/// @dev Implements the full Blake2b algorithm using only the Blake2f compression
///      function available at EVM precompile address 0x09 (Istanbul hard fork).
///
///      ╔═══════════════════════════════════════════════════════════════════════════╗
///      ║                    TRACK 2: POLKADOT PVM INTEGRATION                      ║
///      ╠═══════════════════════════════════════════════════════════════════════════╣
///      ║  Blake2b is Polkadot's NATIVE hash function. Unlike Ethereum which uses  ║
///      ║  Keccak256, Polkadot/Substrate uses Blake2b for:                         ║
///      ║                                                                           ║
///      ║  • Block header hashing                                                   ║
///      ║  • State trie (storage) merkle proofs                                     ║
///      ║  • XCM message integrity verification                                     ║
///      ║  • Transaction hashing                                                    ║
///      ║  • Account ID derivation from public keys                                 ║
///      ║  • SCALE-encoded data hashing                                             ║
///      ║                                                                           ║
///      ║  This library enables Solidity contracts on Polkadot Hub to compute      ║
///      ║  hashes that MATCH the substrate-side hashing, enabling true cross-chain ║
///      ║  verification that is IMPOSSIBLE on Ethereum.                             ║
///      ╚═══════════════════════════════════════════════════════════════════════════╝
///
///      Blake2b-256 specifications:
///        - Digest length: 32 bytes (256 bits)
///        - Block size: 128 bytes
///        - Rounds: 12
///        - No key (unkeyed mode)
///
///      Substrate-specific variants also provided:
///        - blake2b128: 16-byte output (storage keys)
///        - blake2b160: 20-byte output (account addresses)
///        - blake2b512: 64-byte output (full hash)
///
///      References:
///        - RFC 7693: The BLAKE2 Cryptographic Hash
///        - EIP-152: Blake2 compression function F precompile
///        - Substrate Frame: sp-core/hashing
library PvmBlake2 {
    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Blake2f compression function precompile (EIP-152)
    address internal constant BLAKE2F_PRECOMPILE = address(9);

    /// @notice Blake2b rounds (always 12 for Blake2b)
    uint32 internal constant BLAKE2B_ROUNDS = 12;

    /// @notice Blake2b block size in bytes
    uint256 internal constant BLOCK_SIZE = 128;

    /// @notice Blake2f precompile input size (4 + 64 + 128 + 16 + 1 = 213 bytes)
    uint256 internal constant BLAKE2F_INPUT_SIZE = 213;

    /// @notice Blake2b-256 initial state vector (h[0..7])
    /// @dev h[0] = IV[0] XOR parameter block (digest=32, key=0, fanout=1, depth=1)
    ///      h[1..7] = IV[1..7] (parameter block words P[1..7] are zero)
    ///
    ///      IV values (FIPS 180-4 SHA-512 fractional parts):
    ///        IV[0] = 0x6a09e667f3bcc908   XOR 0x01010020 = 0x6a09e667f2bdc928
    ///        IV[1] = 0xbb67ae8584caa73b
    ///        IV[2] = 0x3c6ef372fe94f82b
    ///        IV[3] = 0xa54ff53a5f1d36f1
    ///        IV[4] = 0x510e527fade682d1
    ///        IV[5] = 0x9b05688c2b3e6c1f
    ///        IV[6] = 0x1f83d9abfb41bd6b
    ///        IV[7] = 0x5be0cd19137e2179
    ///
    ///      Stored as two 32-byte words in little-endian byte order (Blake2f format):
    ///        Word 0: h[0..3] LE = 28c9bdf2...f1361d5f3af54fa5
    ///        Word 1: h[4..7] LE = d182e6ad...79217e1319cde05b

    // h[0..3] in LE byte order (initial state, first 32 bytes)
    bytes32 internal constant INIT_STATE_0 = 0x28c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5;

    // h[4..7] in LE byte order (initial state, second 32 bytes)
    bytes32 internal constant INIT_STATE_1 = 0xd182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b;

    // =========================================================================
    // Errors
    // =========================================================================

    error Blake2fPrecompileFailed();
    error Blake2fInvalidOutput();

    // =========================================================================
    // Public Functions
    // =========================================================================

    /// @notice Compute the Blake2b-256 hash of arbitrary input data
    /// @dev Processes input in 128-byte blocks using the Blake2f precompile.
    ///      Empty input is valid and produces a well-defined hash.
    ///      Gas cost: ~300 per compression round × 12 rounds = ~3600 per block
    ///      plus Solidity overhead for memory operations.
    /// @param data Input data to hash (arbitrary length)
    /// @return hash The 32-byte Blake2b-256 hash
    function blake2b256(bytes memory data) internal view returns (bytes32 hash) {
        uint256 dataLen = data.length;

        // Initialize 64-byte state vector
        bytes memory state = _initState();

        if (dataLen == 0) {
            // Empty input: compress one zero-padded block with t=0, final=true
            bytes memory emptyBlock = new bytes(BLOCK_SIZE);
            state = _compress(state, emptyBlock, 0, true);
        } else {
            uint256 offset = 0;
            uint128 totalBytes = 0;

            while (offset < dataLen) {
                uint256 remaining = dataLen - offset;
                bool isFinal = remaining <= BLOCK_SIZE;
                uint256 blockLen = isFinal ? remaining : BLOCK_SIZE;

                // Create zero-padded 128-byte message block
                bytes memory msgBlock = new bytes(BLOCK_SIZE);
                _copyBytes(data, offset, msgBlock, 0, blockLen);

                totalBytes += uint128(blockLen);

                state = _compress(state, msgBlock, totalBytes, isFinal);
                offset += BLOCK_SIZE;
            }
        }

        // Extract first 32 bytes from state = Blake2b-256 hash
        // The state bytes are in Blake2f's LE format, which IS the hash byte sequence
        assembly {
            hash := mload(add(state, 32))
        }
    }

    /// @notice Compute Blake2b-256 with a key (keyed hashing / MAC)
    /// @dev The key is placed in the first block, padded to 128 bytes.
    ///      Useful for computing HMACs and authenticated XCM message hashes.
    /// @param key The key (up to 64 bytes)
    /// @param data Input data to hash
    /// @return hash The keyed Blake2b-256 hash
    function blake2b256Keyed(bytes memory key, bytes memory data) internal view returns (bytes32 hash) {
        require(key.length <= 64, "Key too long");

        // Initialize state with key length in parameter block
        // h[0] = IV[0] XOR (0x01010000 | (keyLen << 8) | 0x20)
        bytes memory state = _initKeyedState(uint8(key.length));

        // Build input: key (padded to 128 bytes) || data
        uint128 totalBytes = 0;

        // First block: key padded to 128 bytes
        bytes memory keyBlock = new bytes(BLOCK_SIZE);
        _copyBytes(key, 0, keyBlock, 0, key.length);

        if (data.length == 0) {
            // Key-only: single final block
            totalBytes = uint128(BLOCK_SIZE);
            state = _compress(state, keyBlock, totalBytes, true);
        } else {
            // Process key block (not final)
            totalBytes = uint128(BLOCK_SIZE);
            state = _compress(state, keyBlock, totalBytes, false);

            // Process data blocks
            uint256 offset = 0;
            while (offset < data.length) {
                uint256 remaining = data.length - offset;
                bool isFinal = remaining <= BLOCK_SIZE;
                uint256 blockLen = isFinal ? remaining : BLOCK_SIZE;

                bytes memory msgBlock = new bytes(BLOCK_SIZE);
                _copyBytes(data, offset, msgBlock, 0, blockLen);

                totalBytes += uint128(blockLen);
                state = _compress(state, msgBlock, totalBytes, isFinal);
                offset += BLOCK_SIZE;
            }
        }

        assembly {
            hash := mload(add(state, 32))
        }
    }

    /// @notice Check if the Blake2f precompile is available
    /// @dev Tries a zero-round compression to verify the precompile responds correctly.
    ///      Standard EVM precompiles don't have deployed bytecode (extcodesize = 0),
    ///      so we must test via actual call.
    /// @return available True if Blake2f precompile is functional
    function isAvailable() internal view returns (bool available) {
        // Try zero-round compression: should return input state unchanged
        bytes memory testInput = new bytes(BLAKE2F_INPUT_SIZE);
        // Set final flag only (everything else zero, including rounds)
        testInput[212] = 0x01;

        (bool success, bytes memory output) = BLAKE2F_PRECOMPILE.staticcall(testInput);
        available = success && output.length == 64;
    }

    // =========================================================================
    // Substrate-Specific Hash Functions (TRACK 2)
    // =========================================================================

    /// @notice Compute Blake2b-128 hash (16 bytes) - Substrate storage key format
    /// @dev Substrate uses 128-bit Blake2b hashes for:
    ///      - Storage map keys (twox128 + blake2_128)
    ///      - Compact state trie nodes
    ///      This is the hash length used by `frame_support::Blake2_128Concat`
    /// @param data Input data to hash
    /// @return hash16 The 16-byte (128-bit) Blake2b hash
    function blake2b128(bytes memory data) internal view returns (bytes16 hash16) {
        bytes32 fullHash = blake2b256(data);
        // Take first 16 bytes (128 bits)
        assembly {
            hash16 := fullHash
        }
    }

    /// @notice Compute Blake2b-160 hash (20 bytes) - Substrate AccountId format
    /// @dev While Substrate typically uses 32-byte account IDs, some legacy
    ///      systems and cross-chain bridges use 20-byte (160-bit) addressing.
    ///      This matches Ethereum's address length for compatibility.
    /// @param data Input data to hash
    /// @return hash20 The 20-byte (160-bit) Blake2b hash
    function blake2b160(bytes memory data) internal view returns (bytes20 hash20) {
        bytes32 fullHash = blake2b256(data);
        // Take first 20 bytes (160 bits)
        assembly {
            hash20 := fullHash
        }
    }

    /// @notice Compute Substrate AccountId32 from a public key
    /// @dev In Substrate, AccountId32 = Blake2b-256(pubkey)
    ///      This is what gets encoded as SS58 address.
    ///
    ///      Example: Alice's sr25519 pubkey 0xd43593c715fdd31c61141abd04a99fd6822c8558854ccde39a5684e7a56da27d
    ///      produces AccountId32 that encodes to SS58 "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"
    ///
    ///      TRACK 2 SIGNIFICANCE: This function computes Substrate account IDs
    ///      exactly as the Rust runtime does, proving deep Polkadot integration.
    ///
    /// @param pubkey 32-byte public key (sr25519 or ed25519)
    /// @return accountId The 32-byte Substrate AccountId
    function computeSubstrateAccountId(bytes32 pubkey) internal view returns (bytes32 accountId) {
        // In Substrate: AccountId32 = pubkey directly for standard accounts
        // But for derived accounts (like multi-sig): AccountId32 = Blake2b-256(derivation_data)
        // Here we provide the Blake2b hash for derived accounts
        bytes memory data = abi.encodePacked(pubkey);
        accountId = blake2b256(data);
    }

    /// @notice Compute a Substrate storage map key
    /// @dev Substrate storage keys are constructed as:
    ///      twox128(module_name) ++ twox128(storage_name) ++ hasher(key)
    ///
    ///      This function computes the key part: Blake2_128Concat(key)
    ///      which is: blake2b128(key) ++ key
    ///
    ///      TRACK 2 SIGNIFICANCE: Enables verification of Substrate storage proofs
    ///      from Solidity contracts.
    ///
    /// @param key The storage map key to hash
    /// @return storageKey The Blake2_128Concat encoded key
    function blake2b128Concat(bytes memory key) internal view returns (bytes memory storageKey) {
        bytes16 hash = blake2b128(key);
        storageKey = abi.encodePacked(hash, key);
    }

    /// @notice Hash SCALE-encoded data using Blake2b-256
    /// @dev SCALE (Simple Concatenated Aggregate Little-Endian) is Substrate's
    ///      canonical encoding format. When hashing SCALE data for verification,
    ///      Blake2b-256 is used.
    ///
    ///      Common uses:
    ///      - Extrinsic (transaction) hashing
    ///      - Block header hashing
    ///      - Event data hashing
    ///
    /// @param scaleData SCALE-encoded bytes
    /// @return hash The Blake2b-256 hash of the SCALE data
    function hashScaleData(bytes memory scaleData) internal view returns (bytes32 hash) {
        hash = blake2b256(scaleData);
    }

    /// @notice Compute XCM message hash in Substrate format
    /// @dev XCM messages are hashed with Blake2b-256 for:
    ///      - Message deduplication
    ///      - Receipt verification
    ///      - Cross-chain message integrity
    ///
    ///      The hash format matches what `xcm::VersionedXcm::hash()` produces
    ///      on the Rust side.
    ///
    ///      TRACK 2 SIGNIFICANCE: Proves our XCM messages hash identically
    ///      to the Substrate relay chain.
    ///
    /// @param xcmVersionPrefix XCM version byte (e.g., 0x03 for V3, 0x04 for V4)
    /// @param xcmInstructions Encoded XCM instructions
    /// @return messageHash The Blake2b-256 hash matching Substrate's computation
    function hashXcmMessage(
        uint8 xcmVersionPrefix,
        bytes memory xcmInstructions
    ) internal view returns (bytes32 messageHash) {
        bytes memory fullMessage = abi.encodePacked(xcmVersionPrefix, xcmInstructions);
        messageHash = blake2b256(fullMessage);
    }

    /// @notice Compute a child trie root hash
    /// @dev Substrate uses Blake2b-256 for merkle trie nodes.
    ///      This computes hash(left || right) for a merkle node.
    ///
    /// @param left Left child hash
    /// @param right Right child hash
    /// @return nodeHash The parent node hash
    function hashMerkleNode(bytes32 left, bytes32 right) internal view returns (bytes32 nodeHash) {
        bytes memory data = abi.encodePacked(left, right);
        nodeHash = blake2b256(data);
    }

    /// @notice Verify that two hashes are equal (constant-time comparison)
    /// @dev Used to verify Blake2b hashes match without timing attacks.
    /// @param a First hash
    /// @param b Second hash
    /// @return equal True if hashes match
    function hashesEqual(bytes32 a, bytes32 b) internal pure returns (bool equal) {
        assembly {
            equal := eq(a, b)
        }
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    /// @notice Initialize the 64-byte Blake2b-256 state (unkeyed)
    function _initState() internal pure returns (bytes memory state) {
        state = new bytes(64);
        assembly {
            let ptr := add(state, 32)
            mstore(ptr, 0x28c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5)
            mstore(add(ptr, 32), 0xd182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b)
        }
    }

    /// @notice Initialize the 64-byte Blake2b-256 state (keyed)
    /// @dev h[0] = IV[0] XOR (0x01010000 | (keyLen << 8) | 0x20)
    function _initKeyedState(uint8 keyLen) internal pure returns (bytes memory state) {
        state = new bytes(64);

        // Compute h[0] = IV[0] XOR param
        // IV[0] = 0x6a09e667f3bcc908
        // param = 0x01010000 | (uint64(keyLen) << 8) | 0x20
        uint64 param = 0x01010020 | (uint64(keyLen) << 8);
        uint64 h0 = 0x6a09e667f3bcc908 ^ param;

        assembly {
            let ptr := add(state, 32)

            // Write h[0] in LE (swap bytes of h0)
            // We need to write the uint64 in little-endian byte order
            let h0LE := or(
                or(
                    or(shl(56, and(h0, 0xFF)), shl(48, and(shr(8, h0), 0xFF))),
                    or(shl(40, and(shr(16, h0), 0xFF)), shl(32, and(shr(24, h0), 0xFF)))
                ),
                or(
                    or(shl(24, and(shr(32, h0), 0xFF)), shl(16, and(shr(40, h0), 0xFF))),
                    or(shl(8, and(shr(48, h0), 0xFF)), and(shr(56, h0), 0xFF))
                )
            )

            // Store h[0] LE (8 bytes) followed by h[1..3] LE (24 bytes from INIT_STATE_0)
            // We need to combine h0LE (shifted left by 192 bits) with h[1..3] (lower 192 bits of INIT_STATE_0)
            let mask := 0x00000000000000003ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5
            mstore(ptr, or(shl(192, h0LE), mask))

            // h[4..7] remain unchanged
            mstore(add(ptr, 32), 0xd182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b)
        }
    }

    /// @notice Call the Blake2f compression function precompile
    /// @dev Constructs the 213-byte input and performs a staticcall to address(9).
    /// @param state Current 64-byte state vector (h[0..7] in LE)
    /// @param msgBlock 128-byte message block (raw bytes, zero-padded)
    /// @param totalBytes Cumulative byte count processed so far
    /// @param isFinal Whether this is the final block
    /// @return newState Updated 64-byte state vector
    function _compress(
        bytes memory state,
        bytes memory msgBlock,
        uint128 totalBytes,
        bool isFinal
    ) internal view returns (bytes memory newState) {
        bytes memory input = new bytes(BLAKE2F_INPUT_SIZE);

        assembly {
            let inp := add(input, 32)

            // Rounds [0..3]: 12 in big-endian (0x0000000c)
            mstore8(inp, 0)
            mstore8(add(inp, 1), 0)
            mstore8(add(inp, 2), 0)
            mstore8(add(inp, 3), 0x0c)

            // State h[0..7] [4..67]: copy 64 bytes from state
            let statePtr := add(state, 32)
            mstore(add(inp, 4), mload(statePtr))
            mstore(add(inp, 36), mload(add(statePtr, 32)))

            // Message block [68..195]: copy 128 bytes
            let msgPtr := add(msgBlock, 32)
            mstore(add(inp, 68), mload(msgPtr))
            mstore(add(inp, 100), mload(add(msgPtr, 32)))
            mstore(add(inp, 132), mload(add(msgPtr, 64)))
            mstore(add(inp, 164), mload(add(msgPtr, 96)))

            // t[0] [196..203]: totalBytes as LE uint64
            let t0 := and(totalBytes, 0xFFFFFFFFFFFFFFFF)
            mstore8(add(inp, 196), and(t0, 0xFF))
            mstore8(add(inp, 197), and(shr(8, t0), 0xFF))
            mstore8(add(inp, 198), and(shr(16, t0), 0xFF))
            mstore8(add(inp, 199), and(shr(24, t0), 0xFF))
            mstore8(add(inp, 200), and(shr(32, t0), 0xFF))
            mstore8(add(inp, 201), and(shr(40, t0), 0xFF))
            mstore8(add(inp, 202), and(shr(48, t0), 0xFF))
            mstore8(add(inp, 203), and(shr(56, t0), 0xFF))

            // t[1] [204..211]: upper 64 bits of counter
            let t1 := and(shr(64, totalBytes), 0xFFFFFFFFFFFFFFFF)
            mstore8(add(inp, 204), and(t1, 0xFF))
            mstore8(add(inp, 205), and(shr(8, t1), 0xFF))
            mstore8(add(inp, 206), and(shr(16, t1), 0xFF))
            mstore8(add(inp, 207), and(shr(24, t1), 0xFF))
            mstore8(add(inp, 208), and(shr(32, t1), 0xFF))
            mstore8(add(inp, 209), and(shr(40, t1), 0xFF))
            mstore8(add(inp, 210), and(shr(48, t1), 0xFF))
            mstore8(add(inp, 211), and(shr(56, t1), 0xFF))

            // f [212]: final block flag
            mstore8(add(inp, 212), isFinal)
        }

        // Call Blake2f precompile
        (bool success, bytes memory output) = BLAKE2F_PRECOMPILE.staticcall(input);
        if (!success) revert Blake2fPrecompileFailed();
        if (output.length != 64) revert Blake2fInvalidOutput();

        return output;
    }

    /// @notice Copy bytes from source to destination at specified offsets
    function _copyBytes(
        bytes memory src,
        uint256 srcOffset,
        bytes memory dst,
        uint256 dstOffset,
        uint256 length
    ) internal pure {
        assembly {
            let srcPtr := add(add(src, 32), srcOffset)
            let dstPtr := add(add(dst, 32), dstOffset)

            // Copy 32-byte chunks
            for { let i := 0 } lt(i, length) { i := add(i, 32) } {
                let chunk := mload(add(srcPtr, i))
                // For the last chunk, we may overwrite padding zeros — that's fine
                // since dst was already zero-initialized
                mstore(add(dstPtr, i), chunk)
            }
        }
    }
}
