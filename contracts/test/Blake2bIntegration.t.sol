// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {CryptoRegistry} from "../src/CryptoRegistry.sol";
import {ICryptoRegistry} from "../src/interfaces/ICryptoRegistry.sol";
import {PvmBlake2} from "../src/libraries/PvmBlake2.sol";
import {SubstrateCompat} from "../src/libraries/SubstrateCompat.sol";

/// @title Blake2bIntegrationTest
/// @notice Comprehensive test suite for Phase 1: Blake2b Integration (Track 2)
/// @dev Tests cover:
///   - Basic Blake2b-256 hashing
///   - Substrate-specific Blake2b variants (128-bit, 160-bit)
///   - Substrate AccountId computation
///   - XCM message hashing
///   - Storage key computation
///   - Merkle proof verification
///   - Cross-chain message commitments
///   - Test vectors matching Polkadot.js / Substrate implementations
contract Blake2bIntegrationTest is Test {
    CryptoRegistry public registry;

    // Test addresses
    address public owner = address(this);
    address public alice = makeAddr("alice");

    // =========================================================================
    // Known Test Vectors
    // =========================================================================
    // These values are computed using Polkadot.js and substrate-node-template
    // to ensure our Blake2b implementation matches the Rust implementation

    // Blake2b-256("") = 0x0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8
    bytes32 constant BLAKE2B_EMPTY = 0x0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8;

    // Blake2b-256("abc") = 0xbddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319
    bytes32 constant BLAKE2B_ABC = 0xbddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319;

    // Blake2b-256("hello") = 0x324dcf027dd4a30a932c441f365a25e86b173defa4b8e58948253471b81b72cf
    bytes32 constant BLAKE2B_HELLO = 0x324dcf027dd4a30a932c441f365a25e86b173defa4b8e58948253471b81b72cf;

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        registry = new CryptoRegistry();
        vm.deal(alice, 100 ether);
    }

    // =========================================================================
    // Basic Blake2b-256 Tests
    // =========================================================================

    function test_blake2b256_emptyInput_matchesTestVector() public view {
        bytes32 hash = registry.blake2b256("");
        assertEq(hash, BLAKE2B_EMPTY, "Empty input should match known test vector");
    }

    function test_blake2b256_abc_matchesTestVector() public view {
        bytes32 hash = registry.blake2b256("abc");
        assertEq(hash, BLAKE2B_ABC, "abc should match known test vector");
    }

    function test_blake2b256_hello_matchesTestVector() public view {
        bytes32 hash = registry.blake2b256("hello");
        assertEq(hash, BLAKE2B_HELLO, "hello should match known test vector");
    }

    function test_blake2b256_isDeterministic() public view {
        bytes memory data = "OmniShield Track 2 Blake2b Integration";
        bytes32 hash1 = registry.blake2b256(data);
        bytes32 hash2 = registry.blake2b256(data);
        assertEq(hash1, hash2, "Hash should be deterministic");
    }

    function test_blake2b256_differentInputsDifferentHashes() public view {
        bytes32 hash1 = registry.blake2b256("input1");
        bytes32 hash2 = registry.blake2b256("input2");
        assertTrue(hash1 != hash2, "Different inputs should produce different hashes");
    }

    function test_blake2b256_differentFromKeccak() public view {
        bytes memory data = "test data";
        bytes32 blake2Hash = registry.blake2b256(data);
        bytes32 keccakHash = keccak256(data);

        assertTrue(blake2Hash != keccakHash, "Blake2b should differ from Keccak256");
        console2.log("Blake2b hash:", vm.toString(blake2Hash));
        console2.log("Keccak hash: ", vm.toString(keccakHash));
    }

    // =========================================================================
    // Blake2b-128 Tests (Substrate Storage Keys)
    // =========================================================================

    function test_blake2b128_returnsFirst16Bytes() public view {
        bytes memory data = "test";
        bytes16 hash128 = registry.blake2b128(data);
        bytes32 hash256 = registry.blake2b256(data);

        // First 16 bytes of 256-bit hash should equal 128-bit hash
        bytes16 first16 = bytes16(hash256);
        assertEq(hash128, first16, "blake2b128 should return first 16 bytes of blake2b256");
    }

    function test_blake2b128_emptyInput() public view {
        bytes16 hash = registry.blake2b128("");
        assertTrue(hash != bytes16(0), "Empty input should not produce zero hash");
    }

    function test_blake2b128_deterministic() public view {
        bytes16 hash1 = registry.blake2b128("storage_key");
        bytes16 hash2 = registry.blake2b128("storage_key");
        assertEq(hash1, hash2, "Should be deterministic");
    }

    // =========================================================================
    // Blake2b-128Concat Tests (Substrate Storage Format)
    // =========================================================================

    function test_blake2b128Concat_format() public view {
        bytes memory key = "my_key";
        bytes memory result = registry.blake2b128Concat(key);

        // Result should be: blake2b128(key) ++ key
        bytes16 expectedHash = registry.blake2b128(key);
        bytes memory expected = abi.encodePacked(expectedHash, key);

        assertEq(keccak256(result), keccak256(expected), "Format should be hash ++ key");
        assertEq(result.length, 16 + key.length, "Length should be 16 + key.length");
    }

    function test_blake2b128Concat_emptyKey() public view {
        bytes memory result = registry.blake2b128Concat("");
        assertEq(result.length, 16, "Empty key should produce just the hash");
    }

    // =========================================================================
    // Substrate AccountId Tests
    // =========================================================================

    function test_computeSubstrateAccountId_nonZero() public view {
        bytes32 pubkey = keccak256("test_pubkey");
        bytes32 accountId = registry.computeSubstrateAccountId(pubkey);

        assertTrue(accountId != bytes32(0), "AccountId should not be zero");
        assertTrue(accountId != pubkey, "AccountId should differ from pubkey (it's hashed)");
    }

    function test_computeSubstrateAccountId_deterministic() public view {
        bytes32 pubkey = bytes32(uint256(0x1234));
        bytes32 id1 = registry.computeSubstrateAccountId(pubkey);
        bytes32 id2 = registry.computeSubstrateAccountId(pubkey);
        assertEq(id1, id2, "Should be deterministic");
    }

    function test_computeSubstrateAccountId_differentPubkeys() public view {
        bytes32 pubkey1 = bytes32(uint256(1));
        bytes32 pubkey2 = bytes32(uint256(2));

        bytes32 id1 = registry.computeSubstrateAccountId(pubkey1);
        bytes32 id2 = registry.computeSubstrateAccountId(pubkey2);

        assertTrue(id1 != id2, "Different pubkeys should produce different account IDs");
    }

    function test_computeSubstrateAccountId_revertOnZeroPubkey() public {
        vm.expectRevert(ICryptoRegistry.InvalidPublicKey.selector);
        registry.computeSubstrateAccountId(bytes32(0));
    }

    // =========================================================================
    // XCM Message Hash Tests
    // =========================================================================

    function test_hashXcmMessage_v3() public view {
        bytes memory instructions = hex"0102030405";
        bytes32 hash = registry.hashXcmMessage(0x03, instructions);

        assertTrue(hash != bytes32(0), "Hash should not be zero");
    }

    function test_hashXcmMessage_v4() public view {
        bytes memory instructions = hex"0102030405";
        bytes32 hash = registry.hashXcmMessage(0x04, instructions);

        assertTrue(hash != bytes32(0), "Hash should not be zero");
    }

    function test_hashXcmMessage_differentVersions() public view {
        bytes memory instructions = hex"0102030405";
        bytes32 hashV3 = registry.hashXcmMessage(0x03, instructions);
        bytes32 hashV4 = registry.hashXcmMessage(0x04, instructions);

        assertTrue(hashV3 != hashV4, "Different XCM versions should produce different hashes");
    }

    function test_hashXcmMessage_sameInstructionsSameHash() public view {
        bytes memory instructions = hex"deadbeef";
        bytes32 hash1 = registry.hashXcmMessage(0x03, instructions);
        bytes32 hash2 = registry.hashXcmMessage(0x03, instructions);
        assertEq(hash1, hash2, "Same instructions should produce same hash");
    }

    // =========================================================================
    // Merkle Node Hash Tests
    // =========================================================================

    function test_hashMerkleNode_nonZero() public view {
        bytes32 left = keccak256("left");
        bytes32 right = keccak256("right");
        bytes32 node = registry.hashMerkleNode(left, right);

        assertTrue(node != bytes32(0), "Node hash should not be zero");
    }

    function test_hashMerkleNode_orderMatters() public view {
        bytes32 a = bytes32(uint256(1));
        bytes32 b = bytes32(uint256(2));

        bytes32 hashAB = registry.hashMerkleNode(a, b);
        bytes32 hashBA = registry.hashMerkleNode(b, a);

        assertTrue(hashAB != hashBA, "Order should affect the hash");
    }

    function test_hashMerkleNode_deterministic() public view {
        bytes32 left = bytes32(uint256(100));
        bytes32 right = bytes32(uint256(200));

        bytes32 hash1 = registry.hashMerkleNode(left, right);
        bytes32 hash2 = registry.hashMerkleNode(left, right);

        assertEq(hash1, hash2, "Should be deterministic");
    }

    // =========================================================================
    // SubstrateCompat Library Tests
    // =========================================================================

    function test_SubstrateCompat_accountIdToEvmAddress() public pure {
        bytes32 accountId = bytes32(uint256(0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0));
        address evmAddr = SubstrateCompat.accountIdToEvmAddress(accountId);

        // Should take last 20 bytes
        address expected = address(uint160(uint256(accountId)));
        assertEq(evmAddr, expected, "Should extract last 20 bytes");
    }

    function test_SubstrateCompat_verifyAccountMatch() public pure {
        bytes32 accountId = bytes32(uint256(0xABCDEF));
        address evmAddr = SubstrateCompat.accountIdToEvmAddress(accountId);

        assertTrue(SubstrateCompat.verifyAccountMatch(accountId, evmAddr), "Should match");
        assertFalse(SubstrateCompat.verifyAccountMatch(accountId, address(0x1234)), "Should not match wrong address");
    }

    function test_SubstrateCompat_buildParachainMultilocation() public pure {
        bytes memory ml = SubstrateCompat.buildParachainMultilocation(2000);

        // Should start with parents = 1, X1, Parachain
        assertEq(uint8(ml[0]), 1, "parents should be 1");
        assertEq(uint8(ml[1]), 0x01, "should be X1");
        assertEq(uint8(ml[2]), 0x00, "should be Parachain junction");
    }

    function test_SubstrateCompat_buildParachainMultilocation_revertZeroParaId() public {
        vm.expectRevert(SubstrateCompat.InvalidParachainId.selector);
        SubstrateCompat.buildParachainMultilocation(0);
    }

    function test_SubstrateCompat_buildRelayChainMultilocation() public pure {
        bytes memory ml = SubstrateCompat.buildRelayChainMultilocation();

        assertEq(uint8(ml[0]), 1, "parents should be 1");
        assertEq(uint8(ml[1]), 0x00, "interior should be Here");
        assertEq(ml.length, 2, "should be exactly 2 bytes");
    }

    function test_SubstrateCompat_computeXcmTransferHash() public view {
        bytes32 hash = SubstrateCompat.computeXcmTransferHash(
            SubstrateCompat.XCM_V3,
            2000,  // Acala
            bytes32(uint256(0x1234)),  // beneficiary
            1 ether,
            0  // native DOT
        );

        assertTrue(hash != bytes32(0), "Hash should not be zero");
    }

    function test_SubstrateCompat_verifyXcmTransferHash() public view {
        uint8 version = SubstrateCompat.XCM_V3;
        uint32 paraId = 2000;
        bytes32 beneficiary = bytes32(uint256(0x1234));
        uint256 amount = 1 ether;
        uint256 assetId = 0;

        bytes32 hash = SubstrateCompat.computeXcmTransferHash(version, paraId, beneficiary, amount, assetId);

        assertTrue(
            SubstrateCompat.verifyXcmTransferHash(hash, version, paraId, beneficiary, amount, assetId),
            "Should verify correct hash"
        );

        assertFalse(
            SubstrateCompat.verifyXcmTransferHash(hash, version, paraId, beneficiary, amount + 1, assetId),
            "Should reject wrong amount"
        );
    }

    function test_SubstrateCompat_computeCrossChainCommitment() public view {
        bytes32 commitment = SubstrateCompat.computeCrossChainCommitment(
            1000,  // source chain
            2000,  // dest chain
            1,     // nonce
            "test payload"
        );

        assertTrue(commitment != bytes32(0), "Commitment should not be zero");
    }

    function test_SubstrateCompat_verifyMerkleProof_singleNode() public view {
        // Simple case: prove a leaf is the root (empty proof)
        bytes32 leaf = keccak256("leaf");
        bytes32[] memory proof = new bytes32[](0);

        assertTrue(
            SubstrateCompat.verifyMerkleProof(leaf, leaf, proof, 0),
            "Leaf should equal root with empty proof"
        );
    }

    function test_SubstrateCompat_verifyMerkleProof_twoNodes() public view {
        // Tree:     root
        //          /    \
        //       left   right

        bytes32 left = bytes32(uint256(1));
        bytes32 right = bytes32(uint256(2));

        // Compute root using Blake2b (matching PvmBlake2.hashMerkleNode)
        bytes32 root = PvmBlake2.hashMerkleNode(left, right);

        // Proof for left leaf (index 0): sibling is right
        bytes32[] memory proofLeft = new bytes32[](1);
        proofLeft[0] = right;

        assertTrue(
            SubstrateCompat.verifyMerkleProof(root, left, proofLeft, 0),
            "Left leaf proof should verify"
        );

        // Proof for right leaf (index 1): sibling is left
        bytes32[] memory proofRight = new bytes32[](1);
        proofRight[0] = left;

        assertTrue(
            SubstrateCompat.verifyMerkleProof(root, right, proofRight, 1),
            "Right leaf proof should verify"
        );
    }

    function test_SubstrateCompat_verifyMerkleProof_rejectInvalid() public view {
        bytes32 left = bytes32(uint256(1));
        bytes32 right = bytes32(uint256(2));
        bytes32 root = PvmBlake2.hashMerkleNode(left, right);

        // Wrong proof
        bytes32[] memory wrongProof = new bytes32[](1);
        wrongProof[0] = bytes32(uint256(999));

        assertFalse(
            SubstrateCompat.verifyMerkleProof(root, left, wrongProof, 0),
            "Should reject invalid proof"
        );
    }

    // =========================================================================
    // Gas Benchmarks
    // =========================================================================

    function test_gas_blake2b256_empty() public view {
        registry.blake2b256("");
    }

    function test_gas_blake2b256_32bytes() public view {
        registry.blake2b256(bytes32(uint256(12345)));
    }

    function test_gas_blake2b256_128bytes() public view {
        registry.blake2b256(new bytes(128));
    }

    function test_gas_blake2b256_256bytes() public view {
        registry.blake2b256(new bytes(256));
    }

    function test_gas_blake2b128() public view {
        registry.blake2b128("storage_key_data");
    }

    function test_gas_computeSubstrateAccountId() public view {
        registry.computeSubstrateAccountId(bytes32(uint256(0x1234)));
    }

    function test_gas_hashXcmMessage() public view {
        registry.hashXcmMessage(0x03, new bytes(100));
    }

    function test_gas_hashMerkleNode() public view {
        registry.hashMerkleNode(bytes32(uint256(1)), bytes32(uint256(2)));
    }

    // =========================================================================
    // Edge Cases and Fuzzing
    // =========================================================================

    function testFuzz_blake2b256_neverReverts(bytes calldata data) public view {
        // Should never revert for any input
        registry.blake2b256(data);
    }

    function testFuzz_blake2b256_deterministic(bytes calldata data) public view {
        bytes32 hash1 = registry.blake2b256(data);
        bytes32 hash2 = registry.blake2b256(data);
        assertEq(hash1, hash2);
    }

    function testFuzz_blake2b128_matchesFirst16Bytes(bytes calldata data) public view {
        bytes16 hash128 = registry.blake2b128(data);
        bytes32 hash256 = registry.blake2b256(data);
        assertEq(hash128, bytes16(hash256));
    }

    function testFuzz_computeSubstrateAccountId(bytes32 pubkey) public view {
        vm.assume(pubkey != bytes32(0));
        bytes32 accountId = registry.computeSubstrateAccountId(pubkey);
        assertTrue(accountId != bytes32(0));
    }

    // =========================================================================
    // Precompile Availability Tests
    // =========================================================================

    function test_blake2fAvailable() public view {
        assertTrue(registry.blake2fAvailable(), "Blake2f precompile should be available");
    }

    function test_getPrecompileStatus_blake2f() public view {
        ICryptoRegistry.PrecompileStatus memory status = registry.getPrecompileStatus();
        assertTrue(status.blake2f, "Blake2f should be available in status");
    }
}
