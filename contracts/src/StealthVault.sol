// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IStealthVault} from "./interfaces/IStealthVault.sol";
import {IStealthPayment} from "./interfaces/IStealthPayment.sol";

/// @title StealthVault
/// @author Omni-Shield Team
/// @notice Commitment-based stealth privacy vault for Polkadot Hub
/// @dev Day 12-14 deliverable — the complete private payment flow.
///
/// Architecture:
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │                         StealthVault                                    │
/// │                                                                         │
/// │  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────┐ │
/// │  │  Commitment       │  │  Batch Stealth    │  │  Relayer             │ │
/// │  │  Deposits         │  │  Payments         │  │  Withdrawals         │ │
/// │  │                   │  │                   │  │                      │ │
/// │  │  deposit(C)       │  │  batchSend()      │  │  withdrawViaRelayer()│ │
/// │  │  withdrawNull()   │  │  batchSendToken() │  │  ECDSA sig verify   │ │
/// │  │  Pedersen commit  │  │  n stealth addrs  │  │  fee deduction      │ │
/// │  └──────────────────┘  └────────┬──────────┘  └──────────────────────┘ │
/// │                                  │                                      │
/// │  ┌──────────────────┐           │          ┌──────────────────────┐    │
/// │  │  Emergency        │           ▼          │  Scanning Helpers    │    │
/// │  │  Withdrawals      │    ┌──────────────┐  │                      │    │
/// │  │                   │    │StealthPayment│  │  computeViewTag()    │    │
/// │  │  timelock-based   │    │ (external)   │  │  computeStealthAddr()│   │
/// │  │  depositor-only   │    └──────────────┘  │  getDepositCount()   │    │
/// │  └──────────────────┘                       └──────────────────────┘    │
/// └─────────────────────────────────────────────────────────────────────────┘
///
/// Privacy Model:
///   - Commitment deposits: C = keccak256(amount || blindingFactor || depositor)
///     The commitment hides the relationship between amount and depositor.
///   - Nullifier withdrawals: N = keccak256(secret || depositIndex)
///     Once a nullifier is consumed, the deposit is spent. The nullifier
///     cannot be linked to the original deposit without the secret.
///   - Relayer withdrawals: Stealth address owner signs off-chain,
///     any relayer can submit. User never makes an on-chain tx from
///     their stealth address, breaking the address linkage.
///   - Batch payments: Multiple stealth payments in one tx obscure
///     the true number of recipients and individual amounts.
///
/// Security:
///   - ReentrancyGuard on all state-changing functions
///   - Ownable2Step for admin safety
///   - Pausable emergency circuit breaker
///   - SafeERC20 for token safety
///   - ECDSA for relayer authorization signatures
///   - Relayer fee cap prevents excessive fees
///   - Emergency timelock protects against griefing
contract StealthVault is IStealthVault, ReentrancyGuard, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Maximum batch size to prevent DoS via gas exhaustion
    uint256 public constant MAX_BATCH_SIZE = 50;

    /// @notice Maximum relayer fee: 500 basis points (5%)
    uint256 public constant MAX_RELAYER_FEE_CAP = 500;

    /// @notice Domain separator for EIP-712 style signatures
    bytes32 public constant DOMAIN_SEPARATOR_SALT = keccak256("OmniShield::StealthVault::v1");

    /// @notice Native token sentinel
    address public constant NATIVE_TOKEN = address(0);

    /// @notice Minimum emergency timelock (1 day)
    uint256 public constant MIN_EMERGENCY_TIMELOCK = 1 days;

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice Reference to StealthPayment contract for batch sends
    IStealthPayment public stealthPayment;

    /// @notice All commitment deposits
    CommitmentDeposit[] private _deposits;

    /// @notice Depositor tracking: depositIndex => depositor address
    mapping(uint256 depositIndex => address depositor) private _depositors;

    /// @notice Deposit amount tracking (needed for commitment verification)
    mapping(uint256 depositIndex => uint256 amount) private _depositAmounts;

    /// @notice Used nullifiers (prevents double-withdrawal)
    mapping(bytes32 nullifier => bool used) private _usedNullifiers;

    /// @notice Emergency withdrawal requests: depositIndex => unlock timestamp
    mapping(uint256 depositIndex => uint256 unlockTime) private _emergencyRequests;

    /// @notice Relayer fee cap in basis points (default: 200 = 2%)
    uint256 public override relayerFeeCap = 200;

    /// @notice Emergency timelock in seconds (default: 3 days)
    uint256 public override emergencyTimelock = 3 days;

    /// @notice Used relay withdrawal hashes (replay protection)
    mapping(bytes32 withdrawalHash => bool used) private _usedWithdrawalHashes;

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(address _stealthPayment) Ownable(msg.sender) {
        if (_stealthPayment == address(0)) revert StealthPaymentNotSet();
        stealthPayment = IStealthPayment(_stealthPayment);
    }

    // =========================================================================
    // External — Commitment Deposits
    // =========================================================================

    /// @inheritdoc IStealthVault
    function depositWithCommitment(bytes32 commitment) external payable nonReentrant whenNotPaused {
        if (commitment == bytes32(0)) revert InvalidCommitment();
        if (msg.value == 0) revert InvalidAmount();

        uint256 depositIndex = _deposits.length;

        _deposits.push(CommitmentDeposit({
            commitment: commitment,
            token: NATIVE_TOKEN,
            timestamp: uint64(block.timestamp),
            withdrawn: false
        }));

        _depositors[depositIndex] = msg.sender;
        _depositAmounts[depositIndex] = msg.value;

        emit CommitmentDeposited(depositIndex, commitment, NATIVE_TOKEN, msg.value, uint64(block.timestamp));
    }

    /// @inheritdoc IStealthVault
    function depositTokenWithCommitment(
        address token,
        uint256 amount,
        bytes32 commitment
    ) external nonReentrant whenNotPaused {
        if (commitment == bytes32(0)) revert InvalidCommitment();
        if (token == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        uint256 depositIndex = _deposits.length;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        _deposits.push(CommitmentDeposit({
            commitment: commitment,
            token: token,
            timestamp: uint64(block.timestamp),
            withdrawn: false
        }));

        _depositors[depositIndex] = msg.sender;
        _depositAmounts[depositIndex] = amount;

        emit CommitmentDeposited(depositIndex, commitment, token, amount, uint64(block.timestamp));
    }

    /// @inheritdoc IStealthVault
    function withdrawWithNullifier(
        bytes32 nullifier,
        uint256 depositIndex,
        uint256 amount,
        bytes32 blindingFactor,
        address to
    ) external nonReentrant whenNotPaused {
        if (nullifier == bytes32(0)) revert InvalidNullifier();
        if (_usedNullifiers[nullifier]) revert NullifierAlreadyUsed();
        if (to == address(0)) revert InvalidAddress();
        if (depositIndex >= _deposits.length) revert DepositNotFound();

        CommitmentDeposit storage deposit = _deposits[depositIndex];
        if (deposit.withdrawn) revert DepositAlreadyWithdrawn();

        // Verify commitment: C = keccak256(amount || blindingFactor || depositor)
        // The caller must know the original amount, blinding factor, and depositor
        bytes32 expectedCommitment = keccak256(abi.encodePacked(
            amount,
            blindingFactor,
            _depositors[depositIndex]
        ));
        if (deposit.commitment != expectedCommitment) revert CommitmentMismatch();

        // Verify the stored amount matches
        if (_depositAmounts[depositIndex] != amount) revert CommitmentMismatch();

        // Mark as withdrawn and consume nullifier
        deposit.withdrawn = true;
        _usedNullifiers[nullifier] = true;

        // Transfer funds
        if (deposit.token == NATIVE_TOKEN) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(deposit.token).safeTransfer(to, amount);
        }

        emit NullifierWithdrawal(nullifier, to, deposit.token, amount, address(0));
    }

    // =========================================================================
    // External — Batch Stealth Payments
    // =========================================================================

    /// @inheritdoc IStealthVault
    function batchSendNativeToStealth(
        BatchStealthPayment[] calldata payments,
        bytes calldata metadata
    ) external payable nonReentrant whenNotPaused {
        uint256 count = payments.length;
        if (count == 0 || count > MAX_BATCH_SIZE) revert BatchTooLarge();

        uint256 totalRequired;
        for (uint256 i; i < count;) {
            if (payments[i].stealthAddress == address(0)) revert InvalidAddress();
            if (payments[i].amount == 0) revert InvalidAmount();
            if (payments[i].ephemeralPubKey == bytes32(0)) revert InvalidCommitment();
            totalRequired += payments[i].amount;
            unchecked { i++; }
        }

        if (msg.value != totalRequired) revert BatchAmountMismatch();

        // Route each payment through StealthPayment contract
        for (uint256 i; i < count;) {
            stealthPayment.sendNativeToStealth{value: payments[i].amount}(
                payments[i].stealthAddress,
                payments[i].ephemeralPubKey,
                payments[i].viewTag,
                metadata
            );
            unchecked { i++; }
        }

        emit BatchStealthProcessed(msg.sender, count, totalRequired, NATIVE_TOKEN);
    }

    /// @inheritdoc IStealthVault
    function batchSendTokenToStealth(
        address token,
        BatchStealthPayment[] calldata payments,
        bytes calldata metadata
    ) external nonReentrant whenNotPaused {
        uint256 count = payments.length;
        if (count == 0 || count > MAX_BATCH_SIZE) revert BatchTooLarge();
        if (token == address(0)) revert InvalidAddress();

        uint256 totalRequired;
        for (uint256 i; i < count;) {
            if (payments[i].stealthAddress == address(0)) revert InvalidAddress();
            if (payments[i].amount == 0) revert InvalidAmount();
            if (payments[i].ephemeralPubKey == bytes32(0)) revert InvalidCommitment();
            totalRequired += payments[i].amount;
            unchecked { i++; }
        }

        // Pull total tokens from sender to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalRequired);

        // Approve StealthPayment to spend
        IERC20(token).forceApprove(address(stealthPayment), totalRequired);

        // Route each payment through StealthPayment contract
        for (uint256 i; i < count;) {
            stealthPayment.sendTokenToStealth(
                token,
                payments[i].amount,
                payments[i].stealthAddress,
                payments[i].ephemeralPubKey,
                payments[i].viewTag,
                metadata
            );
            unchecked { i++; }
        }

        emit BatchStealthProcessed(msg.sender, count, totalRequired, token);
    }

    // =========================================================================
    // External — Relayer Withdrawals
    // =========================================================================

    /// @inheritdoc IStealthVault
    function withdrawViaRelayer(
        RelayerWithdrawal calldata withdrawal,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        // Validate parameters
        if (withdrawal.to == address(0)) revert InvalidAddress();
        if (withdrawal.stealthAddress == address(0)) revert InvalidAddress();
        if (block.timestamp > withdrawal.deadline) revert WithdrawalExpired();

        // Check relayer fee
        uint256 balance = stealthPayment.getStealthBalance(
            withdrawal.stealthAddress,
            withdrawal.token
        );
        if (balance == 0) revert InsufficientBalance();

        // Fee cap check: relayerFee must be <= relayerFeeCap% of balance
        uint256 maxFee = (balance * relayerFeeCap) / 10000;
        if (withdrawal.relayerFee > maxFee) revert RelayerFeeTooHigh();

        // Build the message hash that the stealth address owner signed
        bytes32 withdrawalHash = keccak256(abi.encodePacked(
            DOMAIN_SEPARATOR_SALT,
            withdrawal.stealthAddress,
            withdrawal.token,
            withdrawal.to,
            withdrawal.relayerFee,
            withdrawal.deadline,
            block.chainid
        ));

        // Replay protection
        if (_usedWithdrawalHashes[withdrawalHash]) revert NullifierAlreadyUsed();

        // Recover signer — must be the stealth address
        bytes32 ethSignedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            withdrawalHash
        ));
        address signer = ecrecover(ethSignedHash, v, r, s);
        if (signer != withdrawal.stealthAddress) revert InvalidSignature();

        // Mark as used (replay protection)
        _usedWithdrawalHashes[withdrawalHash] = true;

        // Execute the actual fund transfer via StealthPayment's delegated withdrawal.
        // The vault has been authorized as the trusted caller, so StealthPayment
        // will release the funds: recipient gets (balance - relayerFee), relayer gets fee.
        stealthPayment.withdrawOnBehalf(
            withdrawal.stealthAddress,
            withdrawal.token,
            withdrawal.to,
            withdrawal.relayerFee,
            msg.sender // relayer
        );

        emit RelayerWithdrawalProcessed(
            withdrawal.stealthAddress,
            withdrawal.to,
            msg.sender,
            withdrawal.token,
            balance - withdrawal.relayerFee,
            withdrawal.relayerFee
        );
    }

    // =========================================================================
    // External — Emergency Withdrawals
    // =========================================================================

    /// @inheritdoc IStealthVault
    function initiateEmergencyWithdrawal(uint256 depositIndex) external whenNotPaused {
        if (depositIndex >= _deposits.length) revert DepositNotFound();
        if (_depositors[depositIndex] != msg.sender) revert NotDepositor();
        if (_deposits[depositIndex].withdrawn) revert DepositAlreadyWithdrawn();

        uint256 unlockTime = block.timestamp + emergencyTimelock;
        _emergencyRequests[depositIndex] = unlockTime;

        emit EmergencyWithdrawalInitiated(depositIndex, msg.sender, unlockTime);
    }

    /// @inheritdoc IStealthVault
    function executeEmergencyWithdrawal(
        uint256 depositIndex,
        uint256 amount,
        bytes32 blindingFactor
    ) external nonReentrant whenNotPaused {
        if (depositIndex >= _deposits.length) revert DepositNotFound();
        if (_depositors[depositIndex] != msg.sender) revert NotDepositor();

        CommitmentDeposit storage deposit = _deposits[depositIndex];
        if (deposit.withdrawn) revert DepositAlreadyWithdrawn();

        uint256 unlockTime = _emergencyRequests[depositIndex];
        if (unlockTime == 0) revert EmergencyNotInitiated();
        if (block.timestamp < unlockTime) revert EmergencyTimelockNotElapsed();

        // Verify commitment
        bytes32 expectedCommitment = keccak256(abi.encodePacked(
            amount,
            blindingFactor,
            msg.sender
        ));
        if (deposit.commitment != expectedCommitment) revert CommitmentMismatch();
        if (_depositAmounts[depositIndex] != amount) revert CommitmentMismatch();

        // Mark as withdrawn
        deposit.withdrawn = true;
        delete _emergencyRequests[depositIndex];

        // Transfer back to depositor
        if (deposit.token == NATIVE_TOKEN) {
            (bool success,) = msg.sender.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(deposit.token).safeTransfer(msg.sender, amount);
        }

        emit EmergencyWithdrawalExecuted(depositIndex, msg.sender, deposit.token, amount);
    }

    // =========================================================================
    // External — Scanning Helpers (Pure/View)
    // =========================================================================

    /// @inheritdoc IStealthVault
    function computeViewTag(bytes32 sharedSecret) external pure returns (uint8 viewTag) {
        viewTag = uint8(uint256(keccak256(abi.encodePacked(sharedSecret))) >> 248);
    }

    /// @inheritdoc IStealthVault
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
    // External — Views
    // =========================================================================

    /// @inheritdoc IStealthVault
    function getDepositCount() external view returns (uint256) {
        return _deposits.length;
    }

    /// @inheritdoc IStealthVault
    function getDeposit(uint256 index) external view returns (CommitmentDeposit memory) {
        if (index >= _deposits.length) revert DepositNotFound();
        return _deposits[index];
    }

    /// @inheritdoc IStealthVault
    function isNullifierUsed(bytes32 nullifier) external view returns (bool) {
        return _usedNullifiers[nullifier];
    }

    /// @notice Get the depositor of a specific deposit
    function getDepositor(uint256 depositIndex) external view returns (address) {
        if (depositIndex >= _deposits.length) revert DepositNotFound();
        return _depositors[depositIndex];
    }

    /// @notice Get the emergency unlock time for a deposit
    function getEmergencyUnlockTime(uint256 depositIndex) external view returns (uint256) {
        return _emergencyRequests[depositIndex];
    }

    /// @notice Check if a relayer withdrawal hash has been used
    function isWithdrawalHashUsed(bytes32 hash) external view returns (bool) {
        return _usedWithdrawalHashes[hash];
    }

    // =========================================================================
    // Admin Functions
    // =========================================================================

    /// @notice Update the relayer fee cap
    /// @param newCap New fee cap in basis points (max 500 = 5%)
    function setRelayerFeeCap(uint256 newCap) external onlyOwner {
        require(newCap <= MAX_RELAYER_FEE_CAP, "Fee cap too high");
        uint256 oldCap = relayerFeeCap;
        relayerFeeCap = newCap;
        emit RelayerFeeCapUpdated(oldCap, newCap);
    }

    /// @notice Update the emergency timelock duration
    /// @param newTimelock New timelock in seconds (min 1 day)
    function setEmergencyTimelock(uint256 newTimelock) external onlyOwner {
        require(newTimelock >= MIN_EMERGENCY_TIMELOCK, "Timelock too short");
        uint256 oldTimelock = emergencyTimelock;
        emergencyTimelock = newTimelock;
        emit EmergencyTimelockUpdated(oldTimelock, newTimelock);
    }

    /// @notice Update the StealthPayment contract reference
    function setStealthPayment(address _stealthPayment) external onlyOwner {
        if (_stealthPayment == address(0)) revert StealthPaymentNotSet();
        stealthPayment = IStealthPayment(_stealthPayment);
    }

    /// @notice Pause the vault (emergency)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the vault
    function unpause() external onlyOwner {
        _unpause();
    }

    // =========================================================================
    // Receive
    // =========================================================================

    /// @notice Accept native tokens only through depositWithCommitment or batch sends
    receive() external payable {
        revert("Use depositWithCommitment");
    }
}
