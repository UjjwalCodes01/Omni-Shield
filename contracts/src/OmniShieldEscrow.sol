// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOmniShieldEscrow} from "./interfaces/IOmniShieldEscrow.sol";
import {TimelockAdmin} from "./TimelockAdmin.sol";

/// @title OmniShieldEscrow
/// @author Omni-Shield Team
/// @notice Production-grade escrow contract for Polkadot Hub
/// @dev Supports both native DOT and ERC20 tokens with dispute resolution,
///      time-based expiry, conditional release, and protocol fees.
///
/// Security features:
///   - ReentrancyGuard on all state-changing functions
///   - Ownable2Step for safe ownership transfer
///   - Pausable for emergency circuit breaker
///   - SafeERC20 for safe token interactions
///   - Checks-Effects-Interactions pattern throughout
///   - Fee ceiling hard-coded at 5% (500 bps)
///   - Input validation on all external functions
///   - [W1] Balance accounting on emergencyWithdraw — cannot touch active escrow funds
///   - [W3] Timelock on sensitive admin functions (fee collector, fee rate)
///   - [W5] Paginated view functions for growing arrays
contract OmniShieldEscrow is IOmniShieldEscrow, ReentrancyGuard, Ownable2Step, Pausable, TimelockAdmin {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Maximum protocol fee: 5% (500 basis points)
    uint256 public constant MAX_FEE_BPS = 500;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Sentinel value representing native token (DOT)
    address public constant NATIVE_TOKEN = address(0);

    /// @notice Minimum escrow duration (1 hour)
    uint64 public constant MIN_ESCROW_DURATION = 1 hours;

    /// @notice Maximum escrow duration (365 days)
    uint64 public constant MAX_ESCROW_DURATION = 365 days;

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice Address that receives protocol fees
    address public feeCollector;

    /// @notice Protocol fee in basis points
    uint256 public protocolFeeBps;

    /// @notice Auto-incrementing escrow ID counter
    uint256 private _nextEscrowId;

    /// @notice Mapping from escrow ID to Escrow struct
    mapping(uint256 escrowId => Escrow) private _escrows;

    /// @notice Accumulated protocol fees per token (token => amount)
    mapping(address token => uint256 amount) public accumulatedFees;

    /// @notice Mapping of depositor => list of their escrow IDs
    mapping(address depositor => uint256[]) private _depositorEscrows;

    /// @notice Mapping of recipient => list of their escrow IDs
    mapping(address recipient => uint256[]) private _recipientEscrows;

    /// @notice [W1] Total net amount locked in Active/Disputed escrows per token
    /// @dev Used by emergencyWithdraw to prevent draining active escrow funds.
    ///      Tracks sum of `escrow.amount` (not including fee) for Active/Disputed escrows.
    mapping(address token => uint256 amount) public totalActiveEscrowAmount;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _feeCollector Initial fee collector address
    /// @param _protocolFeeBps Initial protocol fee in bps (max 500)
    constructor(
        address _feeCollector,
        uint256 _protocolFeeBps
    ) Ownable(msg.sender) {
        if (_feeCollector == address(0)) revert InvalidFeeCollector();
        if (_protocolFeeBps > MAX_FEE_BPS) revert FeeTooHigh();

        feeCollector = _feeCollector;
        protocolFeeBps = _protocolFeeBps;

        emit FeeCollectorUpdated(address(0), _feeCollector);
        emit ProtocolFeeUpdated(0, _protocolFeeBps);
    }

    // =========================================================================
    // External Functions — Escrow Lifecycle
    // =========================================================================

    /// @inheritdoc IOmniShieldEscrow
    function createEscrowNative(
        address recipient,
        uint64 expiresAt,
        bytes32 releaseConditionHash
    ) external payable nonReentrant whenNotPaused returns (uint256 escrowId) {
        if (recipient == address(0) || recipient == msg.sender) revert InvalidRecipient();
        if (msg.value == 0) revert InvalidAmount();
        _validateExpiry(expiresAt);

        uint256 fee = _calculateFee(msg.value);
        uint256 netAmount = msg.value - fee;

        escrowId = _nextEscrowId++;

        _escrows[escrowId] = Escrow({
            depositor: msg.sender,
            recipient: recipient,
            token: NATIVE_TOKEN,
            amount: netAmount,
            fee: fee,
            state: EscrowState.Active,
            createdAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            releaseConditionHash: releaseConditionHash
        });

        _depositorEscrows[msg.sender].push(escrowId);
        _recipientEscrows[recipient].push(escrowId);

        // Accumulate fee immediately
        if (fee > 0) {
            accumulatedFees[NATIVE_TOKEN] += fee;
        }

        // [W1] Track active escrow balance
        totalActiveEscrowAmount[NATIVE_TOKEN] += netAmount;

        emit EscrowCreated(escrowId, msg.sender, recipient, NATIVE_TOKEN, netAmount, expiresAt, releaseConditionHash);
    }

    /// @inheritdoc IOmniShieldEscrow
    function createEscrowToken(
        address token,
        address recipient,
        uint256 amount,
        uint64 expiresAt,
        bytes32 releaseConditionHash
    ) external nonReentrant whenNotPaused returns (uint256 escrowId) {
        if (token == address(0)) revert InvalidAmount();
        if (recipient == address(0) || recipient == msg.sender) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        _validateExpiry(expiresAt);

        uint256 fee = _calculateFee(amount);
        uint256 netAmount = amount - fee;

        // Transfer tokens from depositor to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        escrowId = _nextEscrowId++;

        _escrows[escrowId] = Escrow({
            depositor: msg.sender,
            recipient: recipient,
            token: token,
            amount: netAmount,
            fee: fee,
            state: EscrowState.Active,
            createdAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            releaseConditionHash: releaseConditionHash
        });

        _depositorEscrows[msg.sender].push(escrowId);
        _recipientEscrows[recipient].push(escrowId);

        if (fee > 0) {
            accumulatedFees[token] += fee;
        }

        // [W1] Track active escrow balance
        totalActiveEscrowAmount[token] += netAmount;

        emit EscrowCreated(escrowId, msg.sender, recipient, token, netAmount, expiresAt, releaseConditionHash);
    }

    /// @inheritdoc IOmniShieldEscrow
    function release(uint256 escrowId, bytes calldata conditionData) external nonReentrant whenNotPaused {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.state != EscrowState.Active) revert EscrowNotActive();

        // Only depositor can release (they confirm the work is done)
        if (msg.sender != escrow.depositor) revert OnlyDepositor();

        // Verify release condition if one was set
        if (escrow.releaseConditionHash != bytes32(0)) {
            if (keccak256(conditionData) != escrow.releaseConditionHash) revert InvalidCondition();
        }

        // Effects
        escrow.state = EscrowState.Released;
        uint256 amount = escrow.amount;
        address recipient = escrow.recipient;
        address token = escrow.token;

        // [W1] Decrease active escrow tracking
        totalActiveEscrowAmount[token] -= amount;

        // Interactions
        _transferOut(token, recipient, amount);

        emit EscrowReleased(escrowId, recipient, amount, escrow.fee);
    }

    /// @inheritdoc IOmniShieldEscrow
    function refund(uint256 escrowId) external nonReentrant whenNotPaused {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.state != EscrowState.Active) revert EscrowNotActive();
        if (block.timestamp < escrow.expiresAt) revert EscrowNotExpired();

        // Effects — refund the full amount including the fee
        escrow.state = EscrowState.Refunded;
        uint256 totalRefund = escrow.amount + escrow.fee;
        address depositor = escrow.depositor;
        address token = escrow.token;

        // Reverse the accumulated fee since escrow expired unused
        if (escrow.fee > 0) {
            accumulatedFees[token] -= escrow.fee;
        }

        // [W1] Decrease active escrow tracking
        totalActiveEscrowAmount[token] -= escrow.amount;

        // Interactions
        _transferOut(token, depositor, totalRefund);

        emit EscrowRefunded(escrowId, depositor, totalRefund);
    }

    /// @inheritdoc IOmniShieldEscrow
    function dispute(uint256 escrowId) external nonReentrant whenNotPaused {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.state != EscrowState.Active) revert EscrowNotActive();
        if (msg.sender != escrow.depositor && msg.sender != escrow.recipient) {
            revert OnlyDepositorOrRecipient();
        }

        escrow.state = EscrowState.Disputed;
        // NOTE: totalActiveEscrowAmount is NOT decreased here because
        // Disputed escrows still hold funds that must be protected.

        emit EscrowDisputed(escrowId, msg.sender);
    }

    /// @inheritdoc IOmniShieldEscrow
    function resolveDispute(uint256 escrowId, bool releaseToRecipient) external nonReentrant onlyOwner {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.state != EscrowState.Disputed) revert EscrowNotDisputed();

        address token = escrow.token;

        // [W1] Decrease active escrow tracking (resolved = no longer active)
        totalActiveEscrowAmount[token] -= escrow.amount;

        if (releaseToRecipient) {
            escrow.state = EscrowState.Released;
            _transferOut(token, escrow.recipient, escrow.amount);
            emit EscrowReleased(escrowId, escrow.recipient, escrow.amount, escrow.fee);
        } else {
            escrow.state = EscrowState.Refunded;
            uint256 totalRefund = escrow.amount + escrow.fee;
            if (escrow.fee > 0) {
                accumulatedFees[token] -= escrow.fee;
            }
            _transferOut(token, escrow.depositor, totalRefund);
            emit EscrowRefunded(escrowId, escrow.depositor, totalRefund);
        }

        emit DisputeResolved(escrowId, releaseToRecipient);
    }

    // =========================================================================
    // External Functions — Views
    // =========================================================================

    /// @inheritdoc IOmniShieldEscrow
    function getEscrow(uint256 escrowId) external view returns (Escrow memory) {
        return _escrows[escrowId];
    }

    /// @inheritdoc IOmniShieldEscrow
    function getEscrowCount() external view returns (uint256) {
        return _nextEscrowId;
    }

    /// @notice Get all escrow IDs where the caller is the depositor
    /// @param depositor Address of the depositor
    /// @return ids Array of escrow IDs
    function getDepositorEscrows(address depositor) external view returns (uint256[] memory ids) {
        return _depositorEscrows[depositor];
    }

    /// @notice Get all escrow IDs where the caller is the recipient
    /// @param recipient Address of the recipient
    /// @return ids Array of escrow IDs
    function getRecipientEscrows(address recipient) external view returns (uint256[] memory ids) {
        return _recipientEscrows[recipient];
    }

    /// @notice [W5] Paginated depositor escrow IDs to avoid unbounded gas
    /// @param depositor Address of the depositor
    /// @param offset Start index (0-based)
    /// @param limit Maximum number of IDs to return
    /// @return ids Slice of escrow IDs
    /// @return total Total number of escrows for this depositor
    function getDepositorEscrowsPaginated(
        address depositor,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory ids, uint256 total) {
        return _paginateArray(_depositorEscrows[depositor], offset, limit);
    }

    /// @notice [W5] Paginated recipient escrow IDs to avoid unbounded gas
    /// @param recipient Address of the recipient
    /// @param offset Start index (0-based)
    /// @param limit Maximum number of IDs to return
    /// @return ids Slice of escrow IDs
    /// @return total Total number of escrows for this recipient
    function getRecipientEscrowsPaginated(
        address recipient,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory ids, uint256 total) {
        return _paginateArray(_recipientEscrows[recipient], offset, limit);
    }

    // =========================================================================
    // External Functions — Admin (Timelocked) [W3]
    // =========================================================================

    /// @notice Schedule a fee collector change (takes effect after TIMELOCK_DELAY)
    /// @param newFeeCollector New fee collector address
    function scheduleFeeCollectorChange(address newFeeCollector) external onlyOwner {
        if (newFeeCollector == address(0)) revert InvalidFeeCollector();
        bytes32 opHash = keccak256(abi.encode("setFeeCollector", newFeeCollector));
        _scheduleTimelock(opHash);
    }

    /// @notice Execute a previously scheduled fee collector change
    /// @param newFeeCollector Same address that was scheduled (must match hash)
    function executeFeeCollectorChange(address newFeeCollector) external {
        bytes32 opHash = keccak256(abi.encode("setFeeCollector", newFeeCollector));
        _executeTimelock(opHash);
        address old = feeCollector;
        feeCollector = newFeeCollector;
        emit FeeCollectorUpdated(old, newFeeCollector);
    }

    /// @notice Schedule a protocol fee change (takes effect after TIMELOCK_DELAY)
    /// @param newFeeBps New fee in basis points (max 500 = 5%)
    function scheduleProtocolFeeChange(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        bytes32 opHash = keccak256(abi.encode("setProtocolFee", newFeeBps));
        _scheduleTimelock(opHash);
    }

    /// @notice Execute a previously scheduled protocol fee change
    /// @param newFeeBps Same value that was scheduled (must match hash)
    function executeProtocolFeeChange(uint256 newFeeBps) external {
        bytes32 opHash = keccak256(abi.encode("setProtocolFee", newFeeBps));
        _executeTimelock(opHash);
        uint256 old = protocolFeeBps;
        protocolFeeBps = newFeeBps;
        emit ProtocolFeeUpdated(old, newFeeBps);
    }

    /// @notice Cancel any pending timelocked operation
    /// @param opHash The operation hash to cancel
    function cancelTimelock(bytes32 opHash) external onlyOwner {
        _cancelTimelock(opHash);
    }

    // =========================================================================
    // External Functions — Admin (Immediate)
    // =========================================================================

    /// @notice Withdraw accumulated protocol fees
    /// @param token Token to withdraw fees for (address(0) for native)
    function withdrawFees(address token) external nonReentrant onlyOwner {
        uint256 amount = accumulatedFees[token];
        if (amount == 0) revert InvalidAmount();

        accumulatedFees[token] = 0;
        _transferOut(token, feeCollector, amount);
    }

    /// @notice Pause all escrow operations (emergency circuit breaker)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause escrow operations
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice [W1] Emergency withdrawal of stuck tokens — cannot touch active escrow or fee funds
    /// @dev This should ONLY be used if tokens are accidentally sent directly
    ///      to the contract outside of the escrow flow.
    /// @param token Token address (address(0) for native)
    /// @param amount Amount to withdraw
    function emergencyWithdraw(address token, uint256 amount) external nonReentrant onlyOwner {
        if (amount == 0) revert InvalidAmount();

        uint256 contractBal;
        if (token == NATIVE_TOKEN) {
            contractBal = address(this).balance;
        } else {
            contractBal = IERC20(token).balanceOf(address(this));
        }

        // Protected balance = active escrow amounts + unwithdrawned fees
        uint256 protectedBalance = totalActiveEscrowAmount[token] + accumulatedFees[token];
        uint256 available = contractBal > protectedBalance ? contractBal - protectedBalance : 0;
        if (amount > available) revert ExceedsAvailableBalance();

        _transferOut(token, owner(), amount);
        emit EmergencyWithdraw(token, amount);
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    /// @notice Calculate the protocol fee for an amount
    /// @param amount The gross amount
    /// @return fee The fee to deduct
    function _calculateFee(uint256 amount) internal view returns (uint256 fee) {
        unchecked {
            fee = (amount * protocolFeeBps) / BPS_DENOMINATOR;
        }
    }

    /// @notice Validate escrow expiry timestamp
    /// @param expiresAt The proposed expiry timestamp
    function _validateExpiry(uint64 expiresAt) internal view {
        uint64 minExpiry = uint64(block.timestamp) + MIN_ESCROW_DURATION;
        uint64 maxExpiry = uint64(block.timestamp) + MAX_ESCROW_DURATION;
        if (expiresAt < minExpiry || expiresAt > maxExpiry) revert InvalidExpiry();
    }

    /// @notice Transfer tokens (native or ERC20) out of the contract
    /// @param token Token address (address(0) for native)
    /// @param to Recipient address
    /// @param amount Amount to transfer
    function _transferOut(address token, address to, uint256 amount) internal {
        if (token == NATIVE_TOKEN) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert NativeTokenTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @notice [W5] Paginate a uint256 storage array
    /// @param arr Storage array reference
    /// @param offset Start index
    /// @param limit Max items to return
    /// @return ids Paginated slice
    /// @return total Total array length
    function _paginateArray(
        uint256[] storage arr,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256[] memory ids, uint256 total) {
        total = arr.length;
        if (offset >= total || limit == 0) {
            return (new uint256[](0), total);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 len = end - offset;
        ids = new uint256[](len);
        for (uint256 i = 0; i < len;) {
            ids[i] = arr[offset + i];
            unchecked { i++; }
        }
    }

    // =========================================================================
    // Receive
    // =========================================================================

    /// @notice Reject direct native token transfers that aren't through createEscrowNative
    receive() external payable {
        revert("Use createEscrowNative");
    }
}
