// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {CryptoRegistry} from "../src/CryptoRegistry.sol";
import {ICryptoRegistry} from "../src/interfaces/ICryptoRegistry.sol";
import {StealthPayment} from "../src/StealthPayment.sol";
import {IStealthPayment} from "../src/interfaces/IStealthPayment.sol";
import {XcmRouter} from "../src/XcmRouter.sol";
import {XcmTypes} from "../src/libraries/XcmTypes.sol";
import {PvmBlake2} from "../src/libraries/PvmBlake2.sol";
import {PvmVerifier} from "../src/libraries/PvmVerifier.sol";

/// @title CryptoRegistryTest
/// @notice Comprehensive test suite for PVM precompile integration (Day 8-11)
/// @dev Tests cover:
///   - Blake2b-256 hashing via EIP-152 precompile (address 0x09)
///   - BN128 curve operations via EIP-196/197 precompiles (0x06, 0x07, 0x08)
///   - Precompile auto-detection (standard vs substrate-specific)
///   - Stealth address derivation and verification
///   - Substrate auth nonce management
///   - XCM message hash computation (Blake2b vs keccak256)
///   - Integration with StealthPayment (substrate-authorized payments)
///   - Integration with XcmRouter (signed dispatch confirmations)
///   - Ed25519/Sr25519 precompile detection (unavailable on test VM)
///   - Pedersen commitment computation
///   - Batch verification
///   - Admin access control
contract CryptoRegistryTest is Test {
    CryptoRegistry public registry;
    StealthPayment public stealth;
    XcmRouter public xcmRouter;

    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public relayer = makeAddr("relayer");
    address public attacker = makeAddr("attacker");
    address public caller = makeAddr("yieldRouter");

    // Known test values
    bytes32 public constant TEST_SPENDING_KEY = keccak256("test-spending-key");
    bytes32 public constant TEST_VIEWING_KEY = keccak256("test-viewing-key");
    bytes32 public constant TEST_SHARED_SECRET = keccak256("test-shared-secret");
    bytes32 public constant TEST_SUBSTRATE_PUBKEY = keccak256("test-substrate-pubkey");

    // Events
    event PrecompileDetected(string indexed name, address precompileAddr, bool available);
    event SubstrateNonceConsumed(bytes32 indexed pubkeyHash, uint256 nonce);
    event CryptoRegistrySet(address indexed cryptoRegistry);
    event SubstrateStealthPayment(
        address indexed stealthAddress,
        bytes32 indexed substratePubKey,
        uint256 amount,
        uint256 nonce
    );
    event StealthDerivationVerified(
        address indexed stealthAddress,
        bytes32 indexed spendingPubKey,
        bool valid
    );
    event ValidatorTrusted(bytes32 indexed pubkey);
    event ValidatorRevoked(bytes32 indexed pubkey);
    event XcmConfirmedWithSignature(
        uint256 indexed dispatchId,
        uint256 indexed routeId,
        bytes32 indexed validatorPubKey
    );
    event Blake2bXcmHashComputed(
        uint256 indexed dispatchId,
        bytes32 keccakHash,
        bytes32 blake2bHash
    );

    function setUp() public {
        registry = new CryptoRegistry();
        stealth = new StealthPayment();
        xcmRouter = new XcmRouter(relayer);

        // Wire up
        stealth.setCryptoRegistry(address(registry));
        xcmRouter.setCryptoRegistry(address(registry));
        xcmRouter.authorizeCaller(caller);
        registry.authorizeConsumer(address(stealth));

        // Fund accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(caller, 1000 ether);
        vm.deal(attacker, 10 ether);
    }

    // =========================================================================
    // Constructor & Precompile Detection Tests
    // =========================================================================

    function test_constructor_detectsPrecompiles() public view {
        // Blake2f (EIP-152) and BN128 (EIP-196/197) should be available in forge EVM
        assertTrue(registry.blake2fAvailable(), "Blake2f should be available");
        assertTrue(registry.bn128Available(), "BN128 should be available");

        // Sr25519 and Ed25519 are substrate-specific — NOT available in forge
        assertFalse(registry.sr25519Available(), "Sr25519 should not be available in test VM");
        assertFalse(registry.ed25519Available(), "Ed25519 should not be available in test VM");
    }

    function test_getPrecompileStatus_returnsAll() public view {
        ICryptoRegistry.PrecompileStatus memory status = registry.getPrecompileStatus();
        assertTrue(status.blake2f);
        assertTrue(status.bn128);
        assertFalse(status.sr25519);
        assertFalse(status.ed25519);
    }

    function test_refreshPrecompileStatus_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        registry.refreshPrecompileStatus();
    }

    function test_refreshPrecompileStatus_works() public {
        registry.refreshPrecompileStatus();
        assertTrue(registry.blake2fAvailable());
    }

    // =========================================================================
    // Blake2b-256 Hashing Tests
    // =========================================================================

    function test_blake2b256_emptyInput() public view {
        bytes32 hash = registry.blake2b256("");
        // Blake2b-256("") is a well-known constant — verify it's non-zero
        assertTrue(hash != bytes32(0), "Empty input hash should not be zero");
        // The hash should be deterministic
        bytes32 hash2 = registry.blake2b256("");
        assertEq(hash, hash2, "Deterministic hash");
    }

    function test_blake2b256_knownInput() public view {
        bytes32 hash = registry.blake2b256("abc");
        assertTrue(hash != bytes32(0));
        // Different inputs produce different hashes
        bytes32 hash2 = registry.blake2b256("def");
        assertTrue(hash != hash2, "Different inputs should produce different hashes");
    }

    function test_blake2b256_deterministic() public view {
        bytes memory data = "OmniShield cross-chain yield optimizer";
        bytes32 hash1 = registry.blake2b256(data);
        bytes32 hash2 = registry.blake2b256(data);
        assertEq(hash1, hash2);
    }

    function test_blake2b256_differentFromKeccak() public view {
        bytes memory data = "test data";
        bytes32 blake2Hash = registry.blake2b256(data);
        bytes32 keccakHash = keccak256(data);
        // Blake2b and keccak256 should produce entirely different hashes
        assertTrue(blake2Hash != keccakHash, "Blake2b and keccak should differ");
    }

    function test_blake2b256_singleByte() public view {
        bytes32 hash = registry.blake2b256(hex"00");
        assertTrue(hash != bytes32(0));
    }

    function test_blake2b256_exactBlockSize() public view {
        // Exactly 128 bytes = 1 block
        bytes memory data = new bytes(128);
        for (uint256 i = 0; i < 128; i++) {
            data[i] = bytes1(uint8(i & 0xFF));
        }
        bytes32 hash = registry.blake2b256(data);
        assertTrue(hash != bytes32(0));
    }

    function test_blake2b256_multiBlock() public view {
        // 200 bytes = 2 blocks (128 + 72)
        bytes memory data = new bytes(200);
        for (uint256 i = 0; i < 200; i++) {
            data[i] = bytes1(uint8(i & 0xFF));
        }
        bytes32 hash = registry.blake2b256(data);
        assertTrue(hash != bytes32(0));
    }

    function test_blake2b256_largeInput() public view {
        // 512 bytes = 4 blocks
        bytes memory data = new bytes(512);
        for (uint256 i = 0; i < 512; i++) {
            data[i] = bytes1(uint8(i & 0xFF));
        }
        bytes32 hash = registry.blake2b256(data);
        assertTrue(hash != bytes32(0));
    }

    function test_blake2b256Keyed() public view {
        bytes memory key = "secret-key";
        bytes memory data = "test message";

        bytes32 keyedHash = registry.blake2b256Keyed(key, data);
        bytes32 plainHash = registry.blake2b256(data);

        // Keyed hash should differ from plain hash
        assertTrue(keyedHash != plainHash, "Keyed hash should differ from plain");
        assertTrue(keyedHash != bytes32(0));
    }

    function test_blake2b256Keyed_differentKeys() public view {
        bytes memory data = "test";
        bytes32 hash1 = registry.blake2b256Keyed("key1", data);
        bytes32 hash2 = registry.blake2b256Keyed("key2", data);
        assertTrue(hash1 != hash2, "Different keys should produce different hashes");
    }

    function test_blake2b256_fuzz(bytes calldata data) public view {
        // Should not revert for any input
        bytes32 hash = registry.blake2b256(data);
        // Result should be deterministic
        assertEq(hash, registry.blake2b256(data));
    }

    // =========================================================================
    // BN128 Curve Operation Tests
    // =========================================================================

    function test_bn128ScalarMul_generatorTimesOne() public view {
        // G * 1 = G
        (uint256 x, uint256 y) = registry.bn128ScalarMul(1, 2, 1);
        assertEq(x, 1, "G * 1 should give G.x = 1");
        assertEq(y, 2, "G * 1 should give G.y = 2");
    }

    function test_bn128ScalarMul_generatorTimesTwo() public view {
        // G * 2 should be a valid curve point (not G)
        (uint256 x, uint256 y) = registry.bn128ScalarMul(1, 2, 2);
        assertTrue(x != 1 || y != 2, "2G should not equal G");
        assertTrue(x != 0 || y != 0, "2G should not be point at infinity");
    }

    function test_bn128ScalarMul_generatorTimesZero() public view {
        // G * 0 = O (point at infinity)
        (uint256 x, uint256 y) = registry.bn128ScalarMul(1, 2, 0);
        assertEq(x, 0, "G * 0 should be identity.x = 0");
        assertEq(y, 0, "G * 0 should be identity.y = 0");
    }

    function test_bn128PointAdd_identity() public view {
        // G + O = G (adding the identity)
        (uint256 x, uint256 y) = registry.bn128PointAdd(1, 2, 0, 0);
        assertEq(x, 1);
        assertEq(y, 2);
    }

    function test_bn128PointAdd_doubling() public view {
        // G + G = 2G
        (uint256 gx2_add, uint256 gy2_add) = registry.bn128PointAdd(1, 2, 1, 2);
        // Compare with scalar mul: G * 2
        (uint256 gx2_mul, uint256 gy2_mul) = registry.bn128ScalarMul(1, 2, 2);
        assertEq(gx2_add, gx2_mul, "Addition doubling should match scalar mul");
        assertEq(gy2_add, gy2_mul);
    }

    function test_bn128_associativity() public view {
        // (G * 3) + (G * 4) should equal G * 7
        (uint256 x3, uint256 y3) = registry.bn128ScalarMul(1, 2, 3);
        (uint256 x4, uint256 y4) = registry.bn128ScalarMul(1, 2, 4);
        (uint256 xAdd, uint256 yAdd) = registry.bn128PointAdd(x3, y3, x4, y4);

        (uint256 x7, uint256 y7) = registry.bn128ScalarMul(1, 2, 7);
        assertEq(xAdd, x7, "3G + 4G should equal 7G");
        assertEq(yAdd, y7);
    }

    function test_pedersenCommitment() public view {
        // Compute value*G + blinding*H where H = 2G (for testing)
        (uint256 hx, uint256 hy) = registry.bn128ScalarMul(1, 2, 2); // H = 2G

        // C = 5*G + 3*H = 5G + 3*(2G) = 5G + 6G = 11G
        (uint256 cx, uint256 cy) = registry.computePedersenCommitment(5, 3, hx, hy);

        (uint256 expected_x, uint256 expected_y) = registry.bn128ScalarMul(1, 2, 11);
        assertEq(cx, expected_x, "Pedersen commitment should equal 11G");
        assertEq(cy, expected_y);
    }

    function test_pedersenCommitment_hiding() public view {
        (uint256 hx, uint256 hy) = registry.bn128ScalarMul(1, 2, 7); // H = 7G

        // Same value, different blinding factors → different commitments
        (uint256 cx1, uint256 cy1) = registry.computePedersenCommitment(100, 42, hx, hy);
        (uint256 cx2, uint256 cy2) = registry.computePedersenCommitment(100, 99, hx, hy);
        assertTrue(cx1 != cx2 || cy1 != cy2, "Different blindings should give different commitments");
    }

    function test_pedersenCommitment_binding() public view {
        (uint256 hx, uint256 hy) = registry.bn128ScalarMul(1, 2, 7);

        // Different values, same blinding → different commitments
        (uint256 cx1, uint256 cy1) = registry.computePedersenCommitment(100, 42, hx, hy);
        (uint256 cx2, uint256 cy2) = registry.computePedersenCommitment(200, 42, hx, hy);
        assertTrue(cx1 != cx2 || cy1 != cy2, "Different values should give different commitments");
    }

    // =========================================================================
    // Stealth Address Derivation Tests
    // =========================================================================

    function test_computeStealthAddress_deterministic() public view {
        address addr1 = registry.computeStealthAddress(TEST_SPENDING_KEY, TEST_SHARED_SECRET);
        address addr2 = registry.computeStealthAddress(TEST_SPENDING_KEY, TEST_SHARED_SECRET);
        assertEq(addr1, addr2, "Should be deterministic");
        assertTrue(addr1 != address(0), "Should not be zero address");
    }

    function test_computeStealthAddress_differentKeys() public view {
        address addr1 = registry.computeStealthAddress(TEST_SPENDING_KEY, TEST_SHARED_SECRET);
        address addr2 = registry.computeStealthAddress(
            keccak256("other-spending-key"),
            TEST_SHARED_SECRET
        );
        assertTrue(addr1 != addr2, "Different spending keys should give different addresses");
    }

    function test_computeStealthAddress_differentSecrets() public view {
        address addr1 = registry.computeStealthAddress(TEST_SPENDING_KEY, TEST_SHARED_SECRET);
        address addr2 = registry.computeStealthAddress(
            TEST_SPENDING_KEY,
            keccak256("other-shared-secret")
        );
        assertTrue(addr1 != addr2, "Different secrets should give different addresses");
    }

    function test_verifyStealthDerivation_valid() public view {
        address expectedAddr = registry.computeStealthAddress(TEST_SPENDING_KEY, TEST_SHARED_SECRET);
        bool valid = registry.verifyStealthDerivation(TEST_SPENDING_KEY, TEST_SHARED_SECRET, expectedAddr);
        assertTrue(valid, "Should verify correctly derived address");
    }

    function test_verifyStealthDerivation_invalid() public view {
        bool valid = registry.verifyStealthDerivation(TEST_SPENDING_KEY, TEST_SHARED_SECRET, alice);
        assertFalse(valid, "Should reject incorrectly derived address");
    }

    function test_verifyStealthDerivation_fuzz(bytes32 spendKey, bytes32 secret) public view {
        vm.assume(spendKey != bytes32(0) && secret != bytes32(0));
        address derived = registry.computeStealthAddress(spendKey, secret);
        assertTrue(registry.verifyStealthDerivation(spendKey, secret, derived));
        assertFalse(registry.verifyStealthDerivation(spendKey, secret, address(0xdead)));
    }

    // =========================================================================
    // XCM Message Hash Tests (Blake2b)
    // =========================================================================

    function test_computeBlake2bXcmHash() public view {
        bytes32 hash = registry.computeBlake2bXcmHash(1, 2030, 1 ether, bytes32(uint256(1)), 0);
        assertTrue(hash != bytes32(0));
    }

    function test_computeBlake2bXcmHash_deterministic() public view {
        bytes32 hash1 = registry.computeBlake2bXcmHash(1, 2030, 1 ether, bytes32(uint256(1)), 0);
        bytes32 hash2 = registry.computeBlake2bXcmHash(1, 2030, 1 ether, bytes32(uint256(1)), 0);
        assertEq(hash1, hash2);
    }

    function test_computeBlake2bXcmHash_differentParams() public view {
        bytes32 hash1 = registry.computeBlake2bXcmHash(1, 2030, 1 ether, bytes32(uint256(1)), 0);
        bytes32 hash2 = registry.computeBlake2bXcmHash(2, 2030, 1 ether, bytes32(uint256(1)), 0);
        bytes32 hash3 = registry.computeBlake2bXcmHash(1, 2034, 1 ether, bytes32(uint256(1)), 0);
        bytes32 hash4 = registry.computeBlake2bXcmHash(1, 2030, 2 ether, bytes32(uint256(1)), 0);
        assertTrue(hash1 != hash2, "Different routeId");
        assertTrue(hash1 != hash3, "Different paraId");
        assertTrue(hash1 != hash4, "Different amount");
    }

    // =========================================================================
    // Sr25519/Ed25519 Precompile Tests (Unavailable in Test VM)
    // =========================================================================

    function test_verifySr25519_returnsFalseWhenUnavailable() public view {
        // Sr25519 precompile not deployed in forge VM → should return false
        bytes memory fakeSig = new bytes(64);
        bool valid = registry.verifySr25519Signature(TEST_SUBSTRATE_PUBKEY, fakeSig, "hello");
        assertFalse(valid, "Should return false when precompile unavailable");
    }

    function test_verifyEd25519_returnsFalseWhenUnavailable() public view {
        bool valid = registry.verifyEd25519Signature(
            TEST_SUBSTRATE_PUBKEY,
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            "hello"
        );
        assertFalse(valid, "Should return false when precompile unavailable");
    }

    function test_verifySr25519_rejectsInvalidLength() public view {
        bytes memory shortSig = new bytes(32); // Too short
        bool valid = registry.verifySr25519Signature(TEST_SUBSTRATE_PUBKEY, shortSig, "msg");
        assertFalse(valid);
    }

    function test_verifySr25519_rejectsZeroPubkey() public view {
        bytes memory fakeSig = new bytes(64);
        bool valid = registry.verifySr25519Signature(bytes32(0), fakeSig, "msg");
        assertFalse(valid);
    }

    function test_verifyEd25519_rejectsZeroPubkey() public view {
        bool valid = registry.verifyEd25519Signature(
            bytes32(0),
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            "msg"
        );
        assertFalse(valid);
    }

    function test_batchVerifySr25519_allFalseWhenUnavailable() public view {
        bytes32[] memory pks = new bytes32[](3);
        bytes[] memory sigs = new bytes[](3);
        bytes[] memory msgs = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            pks[i] = bytes32(uint256(i + 1));
            sigs[i] = new bytes(64);
            msgs[i] = abi.encodePacked("msg", i);
        }
        bool[] memory results = registry.batchVerifySr25519(pks, sigs, msgs);
        assertEq(results.length, 3);
        for (uint256 i = 0; i < 3; i++) {
            assertFalse(results[i]);
        }
    }

    function test_batchVerifySr25519_revertLengthMismatch() public {
        bytes32[] memory pks = new bytes32[](2);
        bytes[] memory sigs = new bytes[](3);
        bytes[] memory msgs = new bytes[](2);
        vm.expectRevert(ICryptoRegistry.BatchLengthMismatch.selector);
        registry.batchVerifySr25519(pks, sigs, msgs);
    }

    // =========================================================================
    // Sr25519/Ed25519 Mock Precompile Tests (Simulated with vm.etch)
    // =========================================================================

    function test_sr25519_withMockPrecompile() public {
        // Deploy a mock at the sr25519 precompile address that always returns 1 (valid)
        bytes memory mockCode = hex"600160005260206000F3"; // PUSH1 1, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
        vm.etch(PvmVerifier.SR25519_VERIFY, mockCode);

        // Refresh detection
        registry.refreshPrecompileStatus();
        assertTrue(registry.sr25519Available(), "Should detect mock precompile");

        // Verify returns true with mock
        bytes memory sig = new bytes(64);
        bool valid = registry.verifySr25519Signature(TEST_SUBSTRATE_PUBKEY, sig, "hello");
        assertTrue(valid, "Mock precompile should return valid");
    }

    function test_ed25519_withMockPrecompile() public {
        // Deploy a mock at the ed25519 precompile address
        bytes memory mockCode = hex"600160005260206000F3";
        vm.etch(PvmVerifier.ED25519_VERIFY, mockCode);

        registry.refreshPrecompileStatus();
        assertTrue(registry.ed25519Available());

        bool valid = registry.verifyEd25519Signature(
            TEST_SUBSTRATE_PUBKEY,
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            "hello"
        );
        assertTrue(valid);
    }

    function test_sr25519_rejectsInvalid_withMockReturningZero() public {
        // Mock that returns 0 (invalid signature)
        bytes memory mockCode = hex"600060005260206000F3"; // PUSH1 0
        vm.etch(PvmVerifier.SR25519_VERIFY, mockCode);
        registry.refreshPrecompileStatus();

        bytes memory sig = new bytes(64);
        bool valid = registry.verifySr25519Signature(TEST_SUBSTRATE_PUBKEY, sig, "hello");
        assertFalse(valid, "Should reject invalid signature");
    }

    // =========================================================================
    // XCM Message Authentication Tests (with mock precompile)
    // =========================================================================

    function test_verifyXcmMessageAuth_returnsFalseWhenNoPrecompile() public view {
        bytes memory sig = new bytes(64);
        bool valid = registry.verifyXcmMessageAuth(keccak256("test"), TEST_SUBSTRATE_PUBKEY, sig);
        assertFalse(valid);
    }

    function test_verifyXcmMessageAuth_withMockSr25519() public {
        // Mock sr25519 precompile that returns valid
        vm.etch(PvmVerifier.SR25519_VERIFY, hex"600160005260206000F3");
        registry.refreshPrecompileStatus();

        bytes memory sig = new bytes(64);
        bool valid = registry.verifyXcmMessageAuth(keccak256("test"), TEST_SUBSTRATE_PUBKEY, sig);
        assertTrue(valid);
    }

    // =========================================================================
    // Substrate Auth Nonce Tests
    // =========================================================================

    function test_getSubstrateNonce_defaultZero() public view {
        bytes32 pubkeyHash = keccak256(abi.encode(TEST_SUBSTRATE_PUBKEY));
        assertEq(registry.getSubstrateNonce(pubkeyHash), 0);
    }

    function test_consumeSubstrateAuth_revertUnauthorizedCaller() public {
        vm.prank(attacker);
        bytes memory sig = new bytes(64);
        vm.expectRevert(ICryptoRegistry.SignatureVerificationFailed.selector);
        registry.consumeSubstrateAuth(TEST_SUBSTRATE_PUBKEY, sig, "msg", 0);
    }

    function test_consumeSubstrateAuth_revertWhenNoPrecompile() public {
        // Even with authorized consumer, no precompile → verification fails
        vm.expectRevert(ICryptoRegistry.SignatureVerificationFailed.selector);
        registry.consumeSubstrateAuth(TEST_SUBSTRATE_PUBKEY, new bytes(64), "msg", 0);
    }

    function test_consumeSubstrateAuth_withMockPrecompile() public {
        // Deploy mock sr25519 that returns valid
        vm.etch(PvmVerifier.SR25519_VERIFY, hex"600160005260206000F3");
        registry.refreshPrecompileStatus();

        bytes32 pubkeyHash = keccak256(abi.encode(TEST_SUBSTRATE_PUBKEY));
        assertEq(registry.getSubstrateNonce(pubkeyHash), 0);

        bool valid = registry.consumeSubstrateAuth(TEST_SUBSTRATE_PUBKEY, new bytes(64), "msg", 0);
        assertTrue(valid);
        assertEq(registry.getSubstrateNonce(pubkeyHash), 1);
    }

    function test_consumeSubstrateAuth_revertReplayNonce() public {
        vm.etch(PvmVerifier.SR25519_VERIFY, hex"600160005260206000F3");
        registry.refreshPrecompileStatus();

        // First call succeeds
        registry.consumeSubstrateAuth(TEST_SUBSTRATE_PUBKEY, new bytes(64), "msg", 0);

        // Replay with same nonce fails
        vm.expectRevert(ICryptoRegistry.NonceAlreadyUsed.selector);
        registry.consumeSubstrateAuth(TEST_SUBSTRATE_PUBKEY, new bytes(64), "msg", 0);
    }

    function test_consumeSubstrateAuth_sequentialNonces() public {
        vm.etch(PvmVerifier.SR25519_VERIFY, hex"600160005260206000F3");
        registry.refreshPrecompileStatus();

        registry.consumeSubstrateAuth(TEST_SUBSTRATE_PUBKEY, new bytes(64), "msg1", 0);
        registry.consumeSubstrateAuth(TEST_SUBSTRATE_PUBKEY, new bytes(64), "msg2", 1);
        registry.consumeSubstrateAuth(TEST_SUBSTRATE_PUBKEY, new bytes(64), "msg3", 2);

        bytes32 pubkeyHash = keccak256(abi.encode(TEST_SUBSTRATE_PUBKEY));
        assertEq(registry.getSubstrateNonce(pubkeyHash), 3);
    }

    // =========================================================================
    // Admin & Access Control Tests
    // =========================================================================

    function test_authorizeConsumer_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        registry.authorizeConsumer(alice);
    }

    function test_authorizeConsumer_works() public {
        registry.authorizeConsumer(alice);
        assertTrue(registry.isAuthorizedConsumer(alice));
    }

    function test_revokeConsumer_works() public {
        registry.authorizeConsumer(alice);
        registry.revokeConsumer(alice);
        assertFalse(registry.isAuthorizedConsumer(alice));
    }

    function test_pauseUnpause() public {
        registry.pause();
        registry.unpause();
    }

    // =========================================================================
    // Integration: StealthPayment + CryptoRegistry
    // =========================================================================

    function test_stealth_setCryptoRegistry() public view {
        assertEq(address(stealth.cryptoRegistry()), address(registry));
    }

    function test_stealth_setCryptoRegistry_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        stealth.setCryptoRegistry(alice);
    }

    function test_stealth_verifyStealthDerivation() public view {
        address expectedAddr = registry.computeStealthAddress(TEST_SPENDING_KEY, TEST_SHARED_SECRET);
        bool valid = stealth.verifyStealthDerivation(TEST_SPENDING_KEY, TEST_SHARED_SECRET, expectedAddr);
        assertTrue(valid);
    }

    function test_stealth_verifyStealthDerivation_invalid() public view {
        bool valid = stealth.verifyStealthDerivation(TEST_SPENDING_KEY, TEST_SHARED_SECRET, alice);
        assertFalse(valid);
    }

    function test_stealth_sendNativeWithSubstrateAuth_revertNoCryptoRegistry() public {
        // Deploy stealth without CryptoRegistry
        StealthPayment stealthNoCrypto = new StealthPayment();

        vm.prank(alice);
        vm.expectRevert(IStealthPayment.CryptoRegistryNotSet.selector);
        stealthNoCrypto.sendNativeWithSubstrateAuth{value: 1 ether}(
            makeAddr("stealth"),
            keccak256("ephemeral"),
            0x42,
            "",
            TEST_SUBSTRATE_PUBKEY,
            new bytes(64),
            0,
            block.timestamp + 1 hours
        );
    }

    function test_stealth_sendNativeWithSubstrateAuth_revertExpiredDeadline() public {
        vm.prank(alice);
        vm.expectRevert(IStealthPayment.ExpiredDeadline.selector);
        stealth.sendNativeWithSubstrateAuth{value: 1 ether}(
            makeAddr("stealth"),
            keccak256("ephemeral"),
            0x42,
            "",
            TEST_SUBSTRATE_PUBKEY,
            new bytes(64),
            0,
            block.timestamp - 1 // expired
        );
    }

    function test_stealth_sendNativeWithSubstrateAuth_revertInvalidSignature() public {
        // Sr25519 precompile not available → signature verification fails
        vm.prank(alice);
        vm.expectRevert(IStealthPayment.InvalidSignature.selector);
        stealth.sendNativeWithSubstrateAuth{value: 1 ether}(
            makeAddr("stealth"),
            keccak256("ephemeral"),
            0x42,
            "",
            TEST_SUBSTRATE_PUBKEY,
            new bytes(64),
            0,
            block.timestamp + 1 hours
        );
    }

    function test_stealth_sendNativeWithSubstrateAuth_success() public {
        // Mock sr25519 precompile
        vm.etch(PvmVerifier.SR25519_VERIFY, hex"600160005260206000F3");
        registry.refreshPrecompileStatus();

        address stealthAddr = makeAddr("stealth-sub");

        vm.prank(alice);
        stealth.sendNativeWithSubstrateAuth{value: 1 ether}(
            stealthAddr,
            keccak256("ephemeral"),
            0x42,
            "",
            TEST_SUBSTRATE_PUBKEY,
            new bytes(64),
            0,
            block.timestamp + 1 hours
        );

        // Verify payment recorded
        assertEq(stealth.getStealthBalance(stealthAddr, address(0)), 1 ether);
        assertTrue(stealth.isStealthAddressUsed(stealthAddr));

        // Verify nonce incremented
        bytes32 pubkeyHash = keccak256(abi.encode(TEST_SUBSTRATE_PUBKEY));
        assertEq(stealth.getSubstrateNonce(pubkeyHash), 1);
    }

    function test_stealth_substrateAuth_revertReplayNonce() public {
        vm.etch(PvmVerifier.SR25519_VERIFY, hex"600160005260206000F3");
        registry.refreshPrecompileStatus();

        vm.startPrank(alice);

        // First payment succeeds
        stealth.sendNativeWithSubstrateAuth{value: 1 ether}(
            makeAddr("stealth-1"),
            keccak256("eph1"),
            0x42,
            "",
            TEST_SUBSTRATE_PUBKEY,
            new bytes(64),
            0,
            block.timestamp + 1 hours
        );

        // Replay with same nonce fails
        vm.expectRevert(IStealthPayment.InvalidNonce.selector);
        stealth.sendNativeWithSubstrateAuth{value: 1 ether}(
            makeAddr("stealth-2"),
            keccak256("eph2"),
            0x42,
            "",
            TEST_SUBSTRATE_PUBKEY,
            new bytes(64),
            0, // same nonce
            block.timestamp + 1 hours
        );

        vm.stopPrank();
    }

    function test_stealth_substrateAuth_sequentialPayments() public {
        vm.etch(PvmVerifier.SR25519_VERIFY, hex"600160005260206000F3");
        registry.refreshPrecompileStatus();

        vm.startPrank(alice);

        for (uint256 i = 0; i < 5; i++) {
            stealth.sendNativeWithSubstrateAuth{value: 0.1 ether}(
                makeAddr(string(abi.encodePacked("stealth-", i))),
                keccak256(abi.encodePacked("eph-", i)),
                uint8(i),
                "",
                TEST_SUBSTRATE_PUBKEY,
                new bytes(64),
                i, // sequential nonce
                block.timestamp + 1 hours
            );
        }

        vm.stopPrank();

        bytes32 pubkeyHash = keccak256(abi.encode(TEST_SUBSTRATE_PUBKEY));
        assertEq(stealth.getSubstrateNonce(pubkeyHash), 5);
    }

    // =========================================================================
    // Integration: XcmRouter + CryptoRegistry
    // =========================================================================

    function test_xcmRouter_setCryptoRegistry() public view {
        assertEq(address(xcmRouter.cryptoRegistry()), address(registry));
    }

    function test_xcmRouter_addTrustedValidator() public {
        bytes32 validatorPk = keccak256("validator-1");
        xcmRouter.addTrustedValidator(validatorPk);
        assertTrue(xcmRouter.isTrustedValidator(validatorPk));
    }

    function test_xcmRouter_addTrustedValidator_revertZeroPubkey() public {
        vm.expectRevert(XcmRouter.InvalidValidatorPubKey.selector);
        xcmRouter.addTrustedValidator(bytes32(0));
    }

    function test_xcmRouter_removeTrustedValidator() public {
        bytes32 validatorPk = keccak256("validator-1");
        xcmRouter.addTrustedValidator(validatorPk);
        xcmRouter.removeTrustedValidator(validatorPk);
        assertFalse(xcmRouter.isTrustedValidator(validatorPk));
    }

    function test_xcmRouter_confirmDispatchWithSignature_revertNoCryptoRegistry() public {
        XcmRouter routerNoCrypto = new XcmRouter(relayer);
        routerNoCrypto.authorizeCaller(caller);

        // Dispatch first
        vm.prank(caller);
        uint256 dispatchId = routerNoCrypto.dispatchToParachain{value: 1 ether}(1, 2030, 1 ether);

        // Try signed confirmation without CryptoRegistry
        vm.expectRevert(XcmRouter.CryptoRegistryNotSet.selector);
        routerNoCrypto.confirmDispatchWithSignature(dispatchId, keccak256("key"), new bytes(64));
    }

    function test_xcmRouter_confirmDispatchWithSignature_revertUntrustedValidator() public {
        vm.prank(caller);
        uint256 dispatchId = xcmRouter.dispatchToParachain{value: 1 ether}(1, 2030, 1 ether);

        bytes32 validatorPk = keccak256("validator-1");
        // Not trusted yet
        vm.expectRevert(XcmRouter.ValidatorNotTrusted.selector);
        xcmRouter.confirmDispatchWithSignature(dispatchId, validatorPk, new bytes(64));
    }

    function test_xcmRouter_confirmDispatchWithSignature_revertInvalidSignature() public {
        // Setup: dispatch + trust validator, but no precompile
        vm.prank(caller);
        uint256 dispatchId = xcmRouter.dispatchToParachain{value: 1 ether}(1, 2030, 1 ether);

        bytes32 validatorPk = keccak256("validator-1");
        xcmRouter.addTrustedValidator(validatorPk);

        // No sr25519/ed25519 precompile → signature verification fails
        vm.expectRevert(XcmRouter.InvalidSignature.selector);
        xcmRouter.confirmDispatchWithSignature(dispatchId, validatorPk, new bytes(64));
    }

    function test_xcmRouter_confirmDispatchWithSignature_success() public {
        // Mock sr25519 precompile
        vm.etch(PvmVerifier.SR25519_VERIFY, hex"600160005260206000F3");
        registry.refreshPrecompileStatus();

        // Dispatch
        vm.prank(caller);
        uint256 dispatchId = xcmRouter.dispatchToParachain{value: 1 ether}(1, 2030, 1 ether);

        // Trust validator
        bytes32 validatorPk = keccak256("validator-1");
        xcmRouter.addTrustedValidator(validatorPk);

        // Confirm with signature
        xcmRouter.confirmDispatchWithSignature(dispatchId, validatorPk, new bytes(64));

        // Verify confirmed
        XcmTypes.XcmDispatch memory d = xcmRouter.getDispatch(dispatchId);
        assertEq(uint8(d.status), uint8(XcmTypes.XcmStatus.Confirmed));
        assertEq(xcmRouter.pendingDispatches(), 0);
        assertEq(xcmRouter.amountInTransit(), 0);
    }

    function test_xcmRouter_confirmDispatchWithSignature_revertAlreadyConfirmed() public {
        vm.etch(PvmVerifier.SR25519_VERIFY, hex"600160005260206000F3");
        registry.refreshPrecompileStatus();

        vm.prank(caller);
        uint256 dispatchId = xcmRouter.dispatchToParachain{value: 1 ether}(1, 2030, 1 ether);

        bytes32 validatorPk = keccak256("validator-1");
        xcmRouter.addTrustedValidator(validatorPk);

        // First confirmation succeeds
        xcmRouter.confirmDispatchWithSignature(dispatchId, validatorPk, new bytes(64));

        // Second confirmation fails
        vm.expectRevert(XcmRouter.DispatchNotPending.selector);
        xcmRouter.confirmDispatchWithSignature(dispatchId, validatorPk, new bytes(64));
    }

    function test_xcmRouter_computeBlake2bDispatchHash() public {
        vm.prank(caller);
        uint256 dispatchId = xcmRouter.dispatchToParachain{value: 1 ether}(1, 2030, 1 ether);

        bytes32 hash = xcmRouter.computeBlake2bDispatchHash(dispatchId);
        assertTrue(hash != bytes32(0));

        // Should be deterministic
        bytes32 hash2 = xcmRouter.computeBlake2bDispatchHash(dispatchId);
        assertEq(hash, hash2);
    }

    function test_xcmRouter_computeBlake2bDispatchHash_revertNoCryptoRegistry() public {
        XcmRouter routerNoCrypto = new XcmRouter(relayer);
        routerNoCrypto.authorizeCaller(caller);

        vm.prank(caller);
        uint256 dispatchId = routerNoCrypto.dispatchToParachain{value: 1 ether}(1, 2030, 1 ether);

        vm.expectRevert(XcmRouter.CryptoRegistryNotSet.selector);
        routerNoCrypto.computeBlake2bDispatchHash(dispatchId);
    }

    function test_xcmRouter_verifyXcmMessageAuth_falseWhenNoPrecompile() public {
        vm.prank(caller);
        uint256 dispatchId = xcmRouter.dispatchToParachain{value: 1 ether}(1, 2030, 1 ether);

        bool valid = xcmRouter.verifyXcmMessageAuth(dispatchId, TEST_SUBSTRATE_PUBKEY, new bytes(64));
        assertFalse(valid);
    }

    // =========================================================================
    // Edge Case Tests
    // =========================================================================

    function test_blake2b256_oneByteInputs() public view {
        // All single-byte inputs should produce unique hashes
        bytes32 hash0 = registry.blake2b256(hex"00");
        bytes32 hash1 = registry.blake2b256(hex"01");
        bytes32 hashFF = registry.blake2b256(hex"ff");
        assertTrue(hash0 != hash1);
        assertTrue(hash1 != hashFF);
        assertTrue(hash0 != hashFF);
    }

    function test_blake2b256_blockBoundary() public view {
        // Test around the 128-byte block boundary
        bytes memory data127 = new bytes(127);
        bytes memory data128 = new bytes(128);
        bytes memory data129 = new bytes(129);

        bytes32 h127 = registry.blake2b256(data127);
        bytes32 h128 = registry.blake2b256(data128);
        bytes32 h129 = registry.blake2b256(data129);

        assertTrue(h127 != h128, "127 vs 128");
        assertTrue(h128 != h129, "128 vs 129");
        assertTrue(h127 != h129, "127 vs 129");
    }

    function test_bn128ScalarMul_largeScalar() public view {
        // BN128 order - 1 (should produce a valid point)
        uint256 maxScalar = PvmVerifier.BN128_ORDER - 1;
        (uint256 x, uint256 y) = registry.bn128ScalarMul(1, 2, maxScalar);
        assertTrue(x != 0 || y != 0, "Should not be identity");
    }

    function test_computeStealthAddress_consistency() public view {
        // Verify the derivation uses the expected domain separator
        bytes32 expected = keccak256(abi.encodePacked(
            "OmniShield::Stealth::v1",
            TEST_SPENDING_KEY,
            TEST_SHARED_SECRET
        ));
        address expectedAddr = address(uint160(uint256(expected)));
        address derived = registry.computeStealthAddress(TEST_SPENDING_KEY, TEST_SHARED_SECRET);
        assertEq(derived, expectedAddr);
    }

    // =========================================================================
    // Gas Benchmarks
    // =========================================================================

    function test_gas_blake2b256_empty() public view {
        registry.blake2b256("");
    }

    function test_gas_blake2b256_128bytes() public view {
        registry.blake2b256(new bytes(128));
    }

    function test_gas_blake2b256_256bytes() public view {
        registry.blake2b256(new bytes(256));
    }

    function test_gas_bn128ScalarMul() public view {
        registry.bn128ScalarMul(1, 2, 42);
    }

    function test_gas_bn128PointAdd() public view {
        (uint256 x2, uint256 y2) = registry.bn128ScalarMul(1, 2, 2);
        registry.bn128PointAdd(1, 2, x2, y2);
    }

    function test_gas_pedersenCommitment() public view {
        (uint256 hx, uint256 hy) = registry.bn128ScalarMul(1, 2, 7);
        registry.computePedersenCommitment(100, 42, hx, hy);
    }

    function test_gas_computeStealthAddress() public view {
        registry.computeStealthAddress(TEST_SPENDING_KEY, TEST_SHARED_SECRET);
    }

    function test_gas_verifyStealthDerivation() public view {
        address addr = registry.computeStealthAddress(TEST_SPENDING_KEY, TEST_SHARED_SECRET);
        registry.verifyStealthDerivation(TEST_SPENDING_KEY, TEST_SHARED_SECRET, addr);
    }
}
