// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStealthPayment} from "./interfaces/IStealthPayment.sol";
import {ICryptoRegistry} from "./interfaces/ICryptoRegistry.sol";

/// @title StealthPayment
/// @author Omni-Shield Team
/// @notice Simplified EIP-5564 stealth address payment system for Polkadot Hub
/// @dev Provides on-chain stealth meta-address registry, payment routing,
///      and announcement log for recipients to scan and discover payments.
///
/// How it works:
///   1. Recipient registers their stealth meta-address (spendingPubKey + viewingPubKey)
///   2. Sender computes a one-time stealth address off-chain using recipient's meta-address
///   3. Sender calls sendNativeToStealth or sendTokenToStealth — funds go to this contract
///      mapped to the stealth address, and an Announcement event is emitted
///   4. Recipient scans Announcement events using their viewing key, finds matching payments
///   5. Recipient derives the stealth private key off-chain and calls withdrawFromStealth
///
/// Security features:
///   - ReentrancyGuard on all state-changing functions
///   - Ownable2Step for admin safety
///   - Pausable emergency circuit breaker
///   - SafeERC20 for token safety
///   - Balance tracking prevents over-withdrawal
///   - Scheme ID for EIP-5564 forward compatibility
contract StealthPayment is IStealthPayment, ReentrancyGuard, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice EIP-5564 scheme ID: 0 = SECP256k1 with view tags
    uint256 public constant SCHEME_ID = 0;

    /// @notice Scheme ID for Substrate sr25519-authorized payments
    uint256 public constant SUBSTRATE_SCHEME_ID = 1;

    /// @notice Native token sentinel
    address public constant NATIVE_TOKEN = address(0);

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice Stealth meta-address registry: user => meta-address
    mapping(address user => StealthMetaAddress) private _registry;

    /// @notice Stealth address balances: stealthAddress => token => balance
    mapping(address stealthAddr => mapping(address token => uint256 balance)) private _stealthBalances;

    /// @notice Total announcements counter (for indexed scanning)
    uint256 private _announcementCount;

    /// @notice Tracks which stealth addresses have been used (prevent reuse)
    mapping(address stealthAddr => bool) private _usedStealthAddresses;

    /// @notice PVM CryptoRegistry for substrate signature verification and stealth derivation
    ICryptoRegistry public cryptoRegistry;

    /// @notice Nonce tracking for substrate-authorized payments (pubkeyHash => nonce)
    mapping(bytes32 pubkeyHash => uint256) private _substrateNonces;

    /// @notice Relayer fee cap in basis points (default: 200 = 2%)
    uint256 public relayerFeeCap = 200;

    /// @notice Maximum relayer fee cap (5%)
    uint256 public constant MAX_RELAYER_FEE_CAP = 500;

    /// @notice Domain separator for relayer withdrawal signatures
    bytes32 public constant WITHDRAWAL_DOMAIN = keccak256("OmniShield::StealthWithdrawal::v1");

    /// @notice Used withdrawal hashes for replay protection
    mapping(bytes32 => bool) private _usedWithdrawalHashes;

    /// @notice Maximum batch size
    uint256 public constant MAX_BATCH_SIZE = 50;

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor() Ownable(msg.sender) {}

    // =========================================================================
    // External Functions — Registry
    // =========================================================================

    /// @inheritdoc IStealthPayment
    function registerStealthMetaAddress(bytes32 spendingPubKey, bytes32 viewingPubKey) external whenNotPaused {
        if (_registry[msg.sender].isRegistered) revert AlreadyRegistered();
        _validatePubKeys(spendingPubKey, viewingPubKey);

        _registry[msg.sender] = StealthMetaAddress({
            spendingPubKey: spendingPubKey,
            viewingPubKey: viewingPubKey,
            isRegistered: true
        });

        emit StealthMetaAddressRegistered(msg.sender, spendingPubKey, viewingPubKey);
    }

    /// @inheritdoc IStealthPayment
    function updateStealthMetaAddress(bytes32 spendingPubKey, bytes32 viewingPubKey) external whenNotPaused {
        if (!_registry[msg.sender].isRegistered) revert NotRegistered();
        _validatePubKeys(spendingPubKey, viewingPubKey);

        _registry[msg.sender].spendingPubKey = spendingPubKey;
        _registry[msg.sender].viewingPubKey = viewingPubKey;

        emit StealthMetaAddressRegistered(msg.sender, spendingPubKey, viewingPubKey);
    }

    // =========================================================================
    // External Functions — Send Payments
    // =========================================================================

    /// @inheritdoc IStealthPayment
    function sendNativeToStealth(
        address stealthAddress,
        bytes32 ephemeralPubKey,
        uint8 viewTag,
        bytes calldata metadata
    ) external payable nonReentrant whenNotPaused {
        if (stealthAddress == address(0)) revert InvalidStealthAddress();
        if (msg.value == 0) revert InvalidAmount();
        if (ephemeralPubKey == bytes32(0)) revert InvalidPubKey();

        // Track balance for this stealth address
        _stealthBalances[stealthAddress][NATIVE_TOKEN] += msg.value;

        // Mark stealth address as used
        _usedStealthAddresses[stealthAddress] = true;

        unchecked {
            _announcementCount++;
        }

        // Emit EIP-5564 compatible announcement
        emit Announcement(SCHEME_ID, stealthAddress, msg.sender, ephemeralPubKey, metadata);

        // Emit our detailed event
        emit StealthPaymentSent(stealthAddress, ephemeralPubKey, NATIVE_TOKEN, msg.value, viewTag);
    }

    /// @inheritdoc IStealthPayment
    function sendTokenToStealth(
        address token,
        uint256 amount,
        address stealthAddress,
        bytes32 ephemeralPubKey,
        uint8 viewTag,
        bytes calldata metadata
    ) external nonReentrant whenNotPaused {
        if (token == address(0)) revert InvalidStealthAddress();
        if (stealthAddress == address(0)) revert InvalidStealthAddress();
        if (amount == 0) revert InvalidAmount();
        if (ephemeralPubKey == bytes32(0)) revert InvalidPubKey();

        // Transfer tokens to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Track balance
        _stealthBalances[stealthAddress][token] += amount;
        _usedStealthAddresses[stealthAddress] = true;

        unchecked {
            _announcementCount++;
        }

        // Encode token + amount in metadata for EIP-5564 compatibility
        bytes memory fullMetadata = abi.encodePacked(token, amount, metadata);

        emit Announcement(SCHEME_ID, stealthAddress, msg.sender, ephemeralPubKey, fullMetadata);
        emit StealthPaymentSent(stealthAddress, ephemeralPubKey, token, amount, viewTag);
    }

    // =========================================================================
    // External Functions — Withdraw
    // =========================================================================

    /// @inheritdoc IStealthPayment
    function withdrawFromStealth(address token, address to) external nonReentrant whenNotPaused {
        // msg.sender IS the stealth address (they derived the private key)
        address stealthAddr = msg.sender;

        uint256 balance = _stealthBalances[stealthAddr][token];
        if (balance == 0) revert InsufficientBalance();
        if (to == address(0)) revert InvalidStealthAddress();

        // Effects — zero out before transfer
        _stealthBalances[stealthAddr][token] = 0;

        // Interactions
        if (token == NATIVE_TOKEN) {
            (bool success,) = to.call{value: balance}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, balance);
        }

        emit StealthWithdrawal(stealthAddr, to, token, balance);
    }

    // =========================================================================
    // External Functions — Views
    // =========================================================================

    /// @inheritdoc IStealthPayment
    function getStealthMetaAddress(address user) external view returns (StealthMetaAddress memory) {
        return _registry[user];
    }

    /// @inheritdoc IStealthPayment
    function getStealthBalance(address stealthAddress, address token) external view returns (uint256) {
        return _stealthBalances[stealthAddress][token];
    }

    /// @inheritdoc IStealthPayment
    function getAnnouncementCount() external view returns (uint256) {
        return _announcementCount;
    }

    /// @notice Check if a stealth address has been used
    /// @param stealthAddress Address to check
    /// @return used True if the address has received payments
    function isStealthAddressUsed(address stealthAddress) external view returns (bool used) {
        return _usedStealthAddresses[stealthAddress];
    }

    // =========================================================================
    // External Functions — PVM Crypto Integration
    // =========================================================================

    /// @inheritdoc IStealthPayment
    function sendNativeWithSubstrateAuth(
        address stealthAddress,
        bytes32 ephemeralPubKey,
        uint8 viewTag,
        bytes calldata metadata,
        bytes32 substratePubKey,
        bytes calldata signature,
        uint256 nonce,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused {
        if (address(cryptoRegistry) == address(0)) revert CryptoRegistryNotSet();
        if (stealthAddress == address(0)) revert InvalidStealthAddress();
        if (msg.value == 0) revert InvalidAmount();
        if (ephemeralPubKey == bytes32(0)) revert InvalidPubKey();
        if (substratePubKey == bytes32(0)) revert InvalidPubKey();
        if (block.timestamp > deadline) revert ExpiredDeadline();

        // Verify nonce
        bytes32 pubkeyHash = keccak256(abi.encode(substratePubKey));
        if (_substrateNonces[pubkeyHash] != nonce) revert InvalidNonce();

        // Build the message that was signed by the Substrate account
        bytes memory authMessage = abi.encodePacked(
            "OmniShield::StealthAuth::v1",
            stealthAddress,
            ephemeralPubKey,
            viewTag,
            msg.value,
            nonce,
            deadline,
            block.chainid
        );

        // Verify sr25519 signature via CryptoRegistry → PVM precompile (schnorrkel Rust)
        bool valid = cryptoRegistry.verifySr25519Signature(substratePubKey, signature, authMessage);
        if (!valid) revert InvalidSignature();

        // Consume nonce (replay protection)
        _substrateNonces[pubkeyHash] = nonce + 1;

        // Process the stealth payment
        _stealthBalances[stealthAddress][NATIVE_TOKEN] += msg.value;
        _usedStealthAddresses[stealthAddress] = true;

        unchecked {
            _announcementCount++;
        }

        // Emit EIP-5564 announcement with Substrate scheme ID
        emit Announcement(SUBSTRATE_SCHEME_ID, stealthAddress, msg.sender, ephemeralPubKey, metadata);
        emit StealthPaymentSent(stealthAddress, ephemeralPubKey, NATIVE_TOKEN, msg.value, viewTag);
        emit SubstrateStealthPayment(stealthAddress, substratePubKey, msg.value, nonce);
    }

    /// @inheritdoc IStealthPayment
    function verifyStealthDerivation(
        bytes32 spendingPubKey,
        bytes32 sharedSecretHash,
        address stealthAddress
    ) external view returns (bool valid) {
        if (address(cryptoRegistry) == address(0)) revert CryptoRegistryNotSet();
        valid = cryptoRegistry.verifyStealthDerivation(spendingPubKey, sharedSecretHash, stealthAddress);
    }

    /// @notice Get the substrate auth nonce for a public key
    /// @param pubkeyHash keccak256(abi.encode(substratePubKey))
    /// @return nonce The next expected nonce
    function getSubstrateNonce(bytes32 pubkeyHash) external view returns (uint256) {
        return _substrateNonces[pubkeyHash];
    }

    // =========================================================================
    // External Functions — Batch Stealth Payments
    // =========================================================================

    /// @notice Batch stealth payment entry
    /// @param stealthAddress Destination stealth address
    /// @param ephemeralPubKey Ephemeral public key for announcement
    /// @param viewTag View tag for scanning
    /// @param amount Amount to send
    struct BatchEntry {
        address stealthAddress;
        bytes32 ephemeralPubKey;
        uint8 viewTag;
        uint256 amount;
    }

    /// @notice Send native token to multiple stealth addresses in one transaction
    /// @dev Each payment gets its own announcement event for scanning.
    ///      Sum of all amounts must equal msg.value.
    /// @param entries Array of batch payment entries
    /// @param metadata Shared metadata for all payments
    function batchSendNativeToStealth(
        BatchEntry[] calldata entries,
        bytes calldata metadata
    ) external payable nonReentrant whenNotPaused {
        uint256 count = entries.length;
        require(count > 0 && count <= MAX_BATCH_SIZE, "Invalid batch size");

        uint256 totalRequired;
        for (uint256 i; i < count;) {
            require(entries[i].stealthAddress != address(0), "Zero stealth addr");
            require(entries[i].amount > 0, "Zero amount");
            require(entries[i].ephemeralPubKey != bytes32(0), "Zero ephemeral key");
            totalRequired += entries[i].amount;
            unchecked { i++; }
        }
        require(msg.value == totalRequired, "Value mismatch");

        for (uint256 i; i < count;) {
            _recordStealthPayment(entries[i].stealthAddress, NATIVE_TOKEN, entries[i].amount);
            emit Announcement(SCHEME_ID, entries[i].stealthAddress, msg.sender, entries[i].ephemeralPubKey, metadata);
            emit StealthPaymentSent(
                entries[i].stealthAddress, entries[i].ephemeralPubKey,
                NATIVE_TOKEN, entries[i].amount, entries[i].viewTag
            );
            unchecked { i++; }
        }
    }

    /// @notice Send ERC20 token to multiple stealth addresses in one transaction
    /// @param token ERC20 token address
    /// @param entries Array of batch payment entries
    /// @param metadata Shared metadata
    function batchSendTokenToStealth(
        address token,
        BatchEntry[] calldata entries,
        bytes calldata metadata
    ) external nonReentrant whenNotPaused {
        uint256 count = entries.length;
        require(count > 0 && count <= MAX_BATCH_SIZE, "Invalid batch size");
        require(token != address(0), "Invalid token");

        uint256 totalRequired;
        for (uint256 i; i < count;) {
            require(entries[i].stealthAddress != address(0), "Zero stealth addr");
            require(entries[i].amount > 0, "Zero amount");
            require(entries[i].ephemeralPubKey != bytes32(0), "Zero ephemeral key");
            totalRequired += entries[i].amount;
            unchecked { i++; }
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), totalRequired);

        for (uint256 i; i < count;) {
            _recordStealthPayment(entries[i].stealthAddress, token, entries[i].amount);
            _emitTokenAnnouncement(
                entries[i].stealthAddress, entries[i].ephemeralPubKey,
                entries[i].viewTag, token, entries[i].amount, metadata
            );
            unchecked { i++; }
        }
    }

    // =========================================================================
    // External Functions — Relayer Withdrawals
    // =========================================================================

    /// @notice Withdraw from stealth address via a relayer (gasless for stealth owner)
    /// @dev The stealth address owner signs EIP-191 message authorizing withdrawal.
    ///      The relayer submits the tx, pays gas, and receives a fee from the balance.
    /// @param stealthAddress The stealth address holding funds
    /// @param token Token to withdraw
    /// @param to Final destination
    /// @param relayerFee Fee amount for the relayer (from the stealth balance)
    /// @param deadline Signature validity deadline
    /// @param v ECDSA v
    /// @param r ECDSA r
    /// @param s ECDSA s
    function withdrawViaRelayer(
        address stealthAddress,
        address token,
        address to,
        uint256 relayerFee,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        require(stealthAddress != address(0), "Zero stealth addr");
        require(to != address(0), "Zero destination");
        require(block.timestamp <= deadline, "Expired");

        uint256 balance = _stealthBalances[stealthAddress][token];
        require(balance > 0, "No balance");

        // Fee cap check
        require(relayerFee <= (balance * relayerFeeCap) / 10000, "Fee too high");

        // Verify signature and replay protection
        _verifyRelayerSignature(stealthAddress, token, to, relayerFee, deadline, v, r, s);

        // Zero balance before transfer (CEI pattern)
        _stealthBalances[stealthAddress][token] = 0;

        // Execute transfers
        _executeRelayerTransfer(token, to, balance - relayerFee, relayerFee);

        emit StealthWithdrawal(stealthAddress, to, token, balance - relayerFee);
    }

    // =========================================================================
    // External Functions — Scanning Helpers
    // =========================================================================

    /// @notice Compute a view tag from a shared secret
    /// @dev First byte of keccak256(sharedSecret) — used by scanners to quickly
    ///      filter announcements before attempting full stealth key derivation
    /// @param sharedSecret The ECDH shared secret
    /// @return viewTag The first byte
    function computeViewTag(bytes32 sharedSecret) external pure returns (uint8 viewTag) {
        viewTag = uint8(uint256(keccak256(abi.encodePacked(sharedSecret))) >> 248);
    }

    /// @notice Compute a stealth address from meta-address components
    /// @dev Matches CryptoRegistry._deriveStealthAddress() derivation
    /// @param spendingPubKey Recipient's spending public key
    /// @param sharedSecretHash Hash of the ECDH shared secret
    /// @return stealthAddress The derived stealth address
    function computeStealthAddress(
        bytes32 spendingPubKey,
        bytes32 sharedSecretHash
    ) external pure returns (address stealthAddress) {
        stealthAddress = address(uint160(uint256(keccak256(abi.encodePacked(
            "OmniShield::Stealth::v1",
            spendingPubKey,
            sharedSecretHash
        )))));
    }

    // =========================================================================
    // Admin Functions
    // =========================================================================

    /// @notice Set the PVM CryptoRegistry contract
    /// @param _cryptoRegistry Address of the deployed CryptoRegistry
    function setCryptoRegistry(address _cryptoRegistry) external onlyOwner {
        require(_cryptoRegistry != address(0), "Invalid registry");
        cryptoRegistry = ICryptoRegistry(_cryptoRegistry);
        emit CryptoRegistrySet(_cryptoRegistry);
    }

    /// @notice Set the relayer fee cap
    /// @param newCap New fee cap in basis points (max 500 = 5%)
    function setRelayerFeeCap(uint256 newCap) external onlyOwner {
        require(newCap <= MAX_RELAYER_FEE_CAP, "Fee cap too high");
        relayerFeeCap = newCap;
    }

    /// @notice Pause stealth payments (emergency)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause stealth payments
    function unpause() external onlyOwner {
        _unpause();
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    /// @notice Validate public keys are non-zero
    function _validatePubKeys(bytes32 spendingPubKey, bytes32 viewingPubKey) internal pure {
        if (spendingPubKey == bytes32(0) || viewingPubKey == bytes32(0)) revert InvalidPubKey();
    }

    /// @notice Verify relayer withdrawal signature and handle replay protection
    function _verifyRelayerSignature(
        address stealthAddress,
        address token,
        address to,
        uint256 relayerFee,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        bytes32 withdrawalHash = keccak256(abi.encodePacked(
            WITHDRAWAL_DOMAIN,
            stealthAddress,
            token,
            to,
            relayerFee,
            deadline,
            block.chainid
        ));

        require(!_usedWithdrawalHashes[withdrawalHash], "Already used");

        bytes32 ethSignedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            withdrawalHash
        ));
        address signer = ecrecover(ethSignedHash, v, r, s);
        require(signer == stealthAddress, "Invalid signer");

        _usedWithdrawalHashes[withdrawalHash] = true;
    }

    /// @notice Execute relayer transfer: send to recipient and relayer
    function _executeRelayerTransfer(
        address token,
        address to,
        uint256 recipientAmount,
        uint256 relayerFee
    ) internal {
        if (token == NATIVE_TOKEN) {
            (bool success1,) = to.call{value: recipientAmount}("");
            require(success1, "Transfer to recipient failed");

            if (relayerFee > 0) {
                (bool success2,) = msg.sender.call{value: relayerFee}("");
                require(success2, "Transfer to relayer failed");
            }
        } else {
            IERC20(token).safeTransfer(to, recipientAmount);
            if (relayerFee > 0) {
                IERC20(token).safeTransfer(msg.sender, relayerFee);
            }
        }
    }

    /// @notice Record a stealth payment in storage
    function _recordStealthPayment(address stealthAddr, address token, uint256 amount) internal {
        _stealthBalances[stealthAddr][token] += amount;
        _usedStealthAddresses[stealthAddr] = true;
        unchecked { _announcementCount++; }
    }

    /// @notice Emit announcement events for a token stealth payment
    function _emitTokenAnnouncement(
        address stealthAddr,
        bytes32 ephemeralPubKey,
        uint8 viewTag,
        address token,
        uint256 amount,
        bytes calldata metadata
    ) internal {
        bytes memory fullMetadata = abi.encodePacked(token, amount, metadata);
        emit Announcement(SCHEME_ID, stealthAddr, msg.sender, ephemeralPubKey, fullMetadata);
        emit StealthPaymentSent(stealthAddr, ephemeralPubKey, token, amount, viewTag);
    }

    // =========================================================================
    // Receive
    // =========================================================================

    /// @notice Accept native token only through sendNativeToStealth
    receive() external payable {
        revert("Use sendNativeToStealth");
    }
}
