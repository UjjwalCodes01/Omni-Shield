// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IXcmPrecompile} from "./interfaces/IXcmPrecompile.sol";
import {ICryptoRegistry} from "./interfaces/ICryptoRegistry.sol";
import {XcmBuilder} from "./libraries/XcmBuilder.sol";
import {XcmTypes} from "./libraries/XcmTypes.sol";
import {PvmBlake2} from "./libraries/PvmBlake2.sol";

/// @title XcmRouter
/// @author Omni-Shield Team
/// @notice Handles XCM cross-chain fund dispatch and confirmation for Omni-Shield
/// @dev This contract manages the actual cross-chain routing via XCM:
///      1. Builds XCM multilocations for destination parachains
///      2. Dispatches reserve_transfer_assets via the XCM precompile
///      3. Tracks dispatch status (Pending → Confirmed / Failed / TimedOut)
///      4. Handles withdrawal returns from parachains
///
/// Architecture:
///   ┌─────────────────┐     XCM dispatch      ┌──────────────┐
///   │   YieldRouter    │ ──────────────────────▶│  Relay Chain │
///   │  (deposit mgmt)  │                        │  (Polkadot)  │
///   └────────┬─────────┘                        └──────┬───────┘
///            │ calls                                     │ routes
///   ┌────────▼─────────┐                        ┌──────▼───────┐
///   │    XcmRouter      │◀── confirms ──────────│  Parachains  │
///   │  (XCM dispatch)   │   (relayer/oracle)     │  (Bifrost,   │
///   └──────────────────┘                        │   Acala, etc)│
///                                                └──────────────┘
///
/// On-chain flow:
///   1. YieldRouter calls dispatchToParachain() with route details
///   2. XcmRouter builds the XCM message and calls the precompile
///   3. Relayer monitors the dispatch and confirms on destination
///   4. Relayer calls confirmDispatch() or markDispatchFailed()
///   5. On withdrawal, relayer initiates return XCM and calls confirmReturn()
///
/// For testnet: If the XCM precompile is not available (address has no code),
/// the contract falls back to event-based dispatch (relayer picks up events
/// and handles the XCM transfer off-chain via Polkadot.js).
contract XcmRouter is ReentrancyGuard, Ownable2Step, Pausable {
    using XcmBuilder for *;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice XCM precompile address on Polkadot Hub
    /// @dev This is the standard address for pallet-xcm precompile.
    ///      On testnet, this may not be deployed — we handle that gracefully.
    address public constant XCM_PRECOMPILE = 0x0000000000000000000000000000000000000816;

    /// @notice Default XCM execution weight on destination
    uint64 public constant DEFAULT_REF_TIME = 1_000_000_000;
    uint64 public constant DEFAULT_PROOF_SIZE = 65_536;

    /// @notice Default XCM confirmation timeout (6 hours)
    uint64 public constant DEFAULT_TIMEOUT = 6 hours;

    // =========================================================================
    // State
    // =========================================================================

    /// @notice Authorized callers (YieldRouter)
    mapping(address caller => bool) public isAuthorizedCaller;

    /// @notice Authorized oracles/relayers for confirmations
    mapping(address oracle => bool) public isAuthorizedRelayer;
    uint256 public relayerCount;

    /// @notice XCM dispatch tracking: dispatchId => XcmDispatch
    mapping(uint256 dispatchId => XcmTypes.XcmDispatch) private _dispatches;

    /// @notice Route ID => dispatch ID mapping
    mapping(uint256 routeId => uint256 dispatchId) public routeToDispatch;

    /// @notice Auto-incrementing dispatch ID
    uint256 private _nextDispatchId;

    /// @notice Total pending XCM dispatches (for monitoring)
    uint256 public pendingDispatches;

    /// @notice Total amount pending in XCM transit
    uint256 public amountInTransit;

    /// @notice Parachain-specific beneficiary override (paraId => beneficiary)
    /// @dev Some parachains need the funds sent to a specific vault/pool address
    mapping(uint32 paraId => bytes32 beneficiary) public parachainBeneficiary;

    /// @notice Custom weight overrides per parachain
    mapping(uint32 paraId => XcmTypes.XcmRoute) public parachainRouteConfig;

    /// @notice Whether XCM precompile is available (auto-detected)
    bool public xcmPrecompileAvailable;

    /// @notice XCM dispatch nonce (monotonically increasing)
    uint256 private _xcmNonce;

    /// @notice PVM CryptoRegistry for signature verification and Blake2b hashing
    ICryptoRegistry public cryptoRegistry;

    /// @notice Trusted substrate validator public keys for signed confirmations
    mapping(bytes32 pubkey => bool) public isTrustedValidator;

    // =========================================================================
    // Events
    // =========================================================================

    event XcmDispatched(
        uint256 indexed dispatchId,
        uint256 indexed routeId,
        uint32 indexed paraId,
        uint256 amount,
        bytes32 xcmMessageHash
    );

    event XcmConfirmed(
        uint256 indexed dispatchId,
        uint256 indexed routeId,
        uint32 paraId
    );

    event XcmFailed(
        uint256 indexed dispatchId,
        uint256 indexed routeId,
        uint32 paraId,
        string reason
    );

    event XcmTimedOut(
        uint256 indexed dispatchId,
        uint256 indexed routeId
    );

    event XcmReturnInitiated(
        uint256 indexed dispatchId,
        uint256 indexed routeId,
        uint256 amount,
        uint256 yieldEarned
    );

    event XcmReturnConfirmed(
        uint256 indexed dispatchId,
        uint256 indexed routeId,
        uint256 amountReturned
    );

    event CallerAuthorized(address indexed caller);
    event CallerRevoked(address indexed caller);
    event RelayerAuthorized(address indexed relayer);
    event RelayerRevoked(address indexed relayer);
    event BeneficiaryConfigured(uint32 indexed paraId, bytes32 beneficiary);
    event RouteConfigured(uint32 indexed paraId, uint64 weightRefTime, uint64 weightProofSize);
    event PrecompileStatusUpdated(bool available);
    event CryptoRegistrySet(address indexed cryptoRegistry);
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

    // =========================================================================
    // Errors
    // =========================================================================

    error OnlyAuthorizedCaller();
    error OnlyAuthorizedRelayer();
    error DispatchNotFound();
    error DispatchNotPending();
    error DispatchAlreadyConfirmed();
    error InvalidParachain();
    error InvalidBeneficiary();
    error InvalidAmount();
    error XcmDispatchFailed();
    error CannotRemoveLastRelayer();
    error AlreadyAuthorized();
    error NotAuthorized();
    error RouteAlreadyDispatched();
    error DispatchTimedOut();
    error CryptoRegistryNotSet();
    error InvalidValidatorPubKey();
    error ValidatorNotTrusted();
    error InvalidSignature();

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyAuthorizedCaller() {
        if (!isAuthorizedCaller[msg.sender]) revert OnlyAuthorizedCaller();
        _;
    }

    modifier onlyRelayer() {
        if (!isAuthorizedRelayer[msg.sender]) revert OnlyAuthorizedRelayer();
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _relayer Initial relayer address
    constructor(address _relayer) Ownable(msg.sender) {
        if (_relayer == address(0)) revert OnlyAuthorizedRelayer();

        isAuthorizedRelayer[_relayer] = true;
        relayerCount = 1;
        emit RelayerAuthorized(_relayer);

        // Auto-detect XCM precompile availability
        xcmPrecompileAvailable = _hasCode(XCM_PRECOMPILE);
        emit PrecompileStatusUpdated(xcmPrecompileAvailable);
    }

    // =========================================================================
    // External — XCM Dispatch (called by YieldRouter)
    // =========================================================================

    /// @notice Dispatch funds to a parachain via XCM
    /// @dev Called by YieldRouter when a user deposits. Handles the actual
    ///      cross-chain message dispatch.
    /// @param routeId The YieldRouter route ID
    /// @param paraId Destination parachain ID
    /// @param amount Amount of native token to dispatch
    /// @return dispatchId Unique ID for tracking this XCM dispatch
    function dispatchToParachain(
        uint256 routeId,
        uint32 paraId,
        uint256 amount
    ) external payable nonReentrant whenNotPaused onlyAuthorizedCaller returns (uint256 dispatchId) {
        if (paraId == 0) revert InvalidParachain();
        if (amount == 0 || msg.value < amount) revert InvalidAmount();
        if (routeToDispatch[routeId] != 0 && _dispatches[routeToDispatch[routeId]].amount != 0) {
            revert RouteAlreadyDispatched();
        }

        // Get beneficiary for this parachain (or use default: owner as vault)
        bytes32 beneficiary = parachainBeneficiary[paraId];
        if (beneficiary == bytes32(0)) {
            // Default: route to owner's padded address on destination
            beneficiary = bytes32(uint256(uint160(owner())));
        }

        // Build message hash for tracking
        uint256 nonce = _xcmNonce++;
        bytes32 messageHash = XcmBuilder.computeMessageHash(
            routeId, paraId, amount, beneficiary, nonce
        );

        // Create dispatch record
        dispatchId = ++_nextDispatchId;
        _dispatches[dispatchId] = XcmTypes.XcmDispatch({
            routeId: routeId,
            paraId: paraId,
            amount: amount,
            status: XcmTypes.XcmStatus.Pending,
            xcmMessageHash: messageHash,
            dispatchedAt: uint64(block.timestamp),
            confirmedAt: 0,
            timeoutAt: uint64(block.timestamp) + DEFAULT_TIMEOUT
        });

        routeToDispatch[routeId] = dispatchId;
        pendingDispatches++;
        amountInTransit += amount;

        // Attempt XCM precompile dispatch
        bool dispatched = false;
        if (xcmPrecompileAvailable) {
            dispatched = _dispatchViaPrecompile(paraId, beneficiary, amount);
        }

        // If precompile not available or failed, emit event for off-chain relayer
        // This is the fallback path — relayer picks up and dispatches via Polkadot.js
        emit XcmDispatched(dispatchId, routeId, paraId, amount, messageHash);

        // If precompile dispatch failed, we DON'T revert — relayer handles it
        // Funds are held in this contract until confirmation or timeout
    }

    // =========================================================================
    // External — Relayer Confirmations
    // =========================================================================

    /// @notice Confirm that an XCM dispatch was successfully executed on the destination
    /// @param dispatchId The dispatch to confirm
    function confirmDispatch(uint256 dispatchId) external nonReentrant onlyRelayer {
        XcmTypes.XcmDispatch storage d = _dispatches[dispatchId];
        if (d.amount == 0) revert DispatchNotFound();
        if (d.status != XcmTypes.XcmStatus.Pending) revert DispatchNotPending();

        d.status = XcmTypes.XcmStatus.Confirmed;
        d.confirmedAt = uint64(block.timestamp);

        unchecked {
            pendingDispatches--;
            amountInTransit -= d.amount;
        }

        emit XcmConfirmed(dispatchId, d.routeId, d.paraId);
    }

    /// @notice Mark an XCM dispatch as failed (relayer detected failure on destination)
    /// @param dispatchId The failed dispatch
    /// @param reason Human-readable failure reason
    function markDispatchFailed(
        uint256 dispatchId,
        string calldata reason
    ) external nonReentrant onlyRelayer {
        XcmTypes.XcmDispatch storage d = _dispatches[dispatchId];
        if (d.amount == 0) revert DispatchNotFound();
        if (d.status != XcmTypes.XcmStatus.Pending) revert DispatchNotPending();

        d.status = XcmTypes.XcmStatus.Failed;

        unchecked {
            pendingDispatches--;
            amountInTransit -= d.amount;
        }

        emit XcmFailed(dispatchId, d.routeId, d.paraId, reason);
    }

    /// @notice Mark a dispatch as timed out (no confirmation within timeout window)
    /// @dev Anyone can call this after the timeout — no oracle needed
    /// @param dispatchId The timed-out dispatch
    function markTimedOut(uint256 dispatchId) external nonReentrant {
        XcmTypes.XcmDispatch storage d = _dispatches[dispatchId];
        if (d.amount == 0) revert DispatchNotFound();
        if (d.status != XcmTypes.XcmStatus.Pending) revert DispatchNotPending();
        if (uint64(block.timestamp) < d.timeoutAt) revert DispatchNotPending();

        d.status = XcmTypes.XcmStatus.TimedOut;

        unchecked {
            pendingDispatches--;
            amountInTransit -= d.amount;
        }

        emit XcmTimedOut(dispatchId, d.routeId);
    }

    /// @notice Initiate a return XCM transfer (withdrawal from parachain)
    /// @dev Called by relayer when YieldRouter initiates a withdrawal.
    ///      The relayer monitors withdrawal events and starts the return.
    /// @param dispatchId The dispatch whose funds are being returned
    /// @param yieldEarned Yield earned on the parachain
    function initiateReturn(
        uint256 dispatchId,
        uint256 yieldEarned
    ) external nonReentrant onlyRelayer {
        XcmTypes.XcmDispatch storage d = _dispatches[dispatchId];
        if (d.amount == 0) revert DispatchNotFound();
        if (d.status != XcmTypes.XcmStatus.Confirmed) revert DispatchNotPending();

        emit XcmReturnInitiated(dispatchId, d.routeId, d.amount, yieldEarned);
    }

    /// @notice Confirm that return funds have arrived back from the parachain
    /// @param dispatchId The dispatch whose funds were returned
    function confirmReturn(uint256 dispatchId) external payable nonReentrant onlyRelayer {
        XcmTypes.XcmDispatch storage d = _dispatches[dispatchId];
        if (d.amount == 0) revert DispatchNotFound();

        emit XcmReturnConfirmed(dispatchId, d.routeId, msg.value);
    }

    // =========================================================================
    // External — Views
    // =========================================================================

    /// @notice Get a dispatch record
    function getDispatch(uint256 dispatchId) external view returns (XcmTypes.XcmDispatch memory) {
        return _dispatches[dispatchId];
    }

    /// @notice Get the dispatch ID for a route
    function getDispatchForRoute(uint256 routeId) external view returns (uint256) {
        return routeToDispatch[routeId];
    }

    /// @notice Get total dispatch count
    function getDispatchCount() external view returns (uint256) {
        return _nextDispatchId;
    }

    /// @notice Check if a dispatch is past its timeout
    function isTimedOut(uint256 dispatchId) external view returns (bool) {
        XcmTypes.XcmDispatch storage d = _dispatches[dispatchId];
        return d.status == XcmTypes.XcmStatus.Pending && uint64(block.timestamp) >= d.timeoutAt;
    }

    // =========================================================================
    // External — PVM Crypto: Signed Confirmations
    // =========================================================================

    /// @notice Confirm a dispatch using a substrate validator's sr25519/ed25519 signature
    /// @dev Instead of trusting a relayer address, this verifies a cryptographic
    ///      signature from a trusted validator. The signature is verified via the
    ///      PVM sr25519 precompile (schnorrkel Rust crate).
    ///
    ///      Signed message: keccak256(abi.encodePacked("OmniShield::XCM::Confirm", dispatchId, messageHash))
    ///
    /// @param dispatchId The dispatch to confirm
    /// @param validatorPubKey The sr25519/ed25519 public key of the signing validator
    /// @param signature The 64-byte signature over the confirmation message
    function confirmDispatchWithSignature(
        uint256 dispatchId,
        bytes32 validatorPubKey,
        bytes calldata signature
    ) external nonReentrant {
        if (address(cryptoRegistry) == address(0)) revert CryptoRegistryNotSet();
        if (validatorPubKey == bytes32(0)) revert InvalidValidatorPubKey();
        if (!isTrustedValidator[validatorPubKey]) revert ValidatorNotTrusted();

        XcmTypes.XcmDispatch storage d = _dispatches[dispatchId];
        if (d.amount == 0) revert DispatchNotFound();
        if (d.status != XcmTypes.XcmStatus.Pending) revert DispatchNotPending();

        // Build the confirmation message
        bytes memory confirmMsg = abi.encodePacked(
            "OmniShield::XCM::Confirm::v1",
            dispatchId,
            d.xcmMessageHash,
            d.paraId,
            block.chainid
        );

        // Verify signature via CryptoRegistry → PVM precompile
        bool valid = cryptoRegistry.verifySr25519Signature(validatorPubKey, signature, confirmMsg);
        if (!valid) {
            // Fallback: try ed25519
            if (signature.length == 64) {
                bytes32 sigR = bytes32(signature[0:32]);
                bytes32 sigS = bytes32(signature[32:64]);
                valid = cryptoRegistry.verifyEd25519Signature(validatorPubKey, sigR, sigS, confirmMsg);
            }
        }
        if (!valid) revert InvalidSignature();

        // Confirm the dispatch
        d.status = XcmTypes.XcmStatus.Confirmed;
        d.confirmedAt = uint64(block.timestamp);

        unchecked {
            pendingDispatches--;
            amountInTransit -= d.amount;
        }

        emit XcmConfirmed(dispatchId, d.routeId, d.paraId);
        emit XcmConfirmedWithSignature(dispatchId, d.routeId, validatorPubKey);
    }

    /// @notice Compute a Blake2b-based XCM message hash (matches substrate-side hashing)
    /// @dev Uses the PVM Blake2b precompile to compute a hash that matches the
    ///      hash computed on the substrate side of the XCM bridge. This enables
    ///      on-chain verification that the message hash matches the relay chain.
    /// @param dispatchId The dispatch to compute hash for
    /// @return blake2bHash The Blake2b-256 hash of the XCM message
    function computeBlake2bDispatchHash(uint256 dispatchId) external view returns (bytes32 blake2bHash) {
        if (address(cryptoRegistry) == address(0)) revert CryptoRegistryNotSet();

        XcmTypes.XcmDispatch storage d = _dispatches[dispatchId];
        if (d.amount == 0) revert DispatchNotFound();

        blake2bHash = cryptoRegistry.computeBlake2bXcmHash(
            d.routeId,
            d.paraId,
            d.amount,
            parachainBeneficiary[d.paraId],
            dispatchId
        );
    }

    /// @notice Verify XCM message authentication with a substrate signature
    /// @param dispatchId The dispatch to verify
    /// @param pubkey Validator/collator public key
    /// @param signature Signature over the dispatch message hash
    /// @return valid True if the signature is valid
    function verifyXcmMessageAuth(
        uint256 dispatchId,
        bytes32 pubkey,
        bytes calldata signature
    ) external view returns (bool valid) {
        if (address(cryptoRegistry) == address(0)) return false;

        XcmTypes.XcmDispatch storage d = _dispatches[dispatchId];
        if (d.amount == 0) return false;

        valid = cryptoRegistry.verifyXcmMessageAuth(d.xcmMessageHash, pubkey, signature);
    }

    // =========================================================================
    // External — Admin
    // =========================================================================

    /// @notice Authorize a caller (YieldRouter) to dispatch XCM
    function authorizeCaller(address caller) external onlyOwner {
        if (caller == address(0)) revert OnlyAuthorizedCaller();
        if (isAuthorizedCaller[caller]) revert AlreadyAuthorized();
        isAuthorizedCaller[caller] = true;
        emit CallerAuthorized(caller);
    }

    /// @notice Revoke a caller's authorization
    function revokeCaller(address caller) external onlyOwner {
        if (!isAuthorizedCaller[caller]) revert NotAuthorized();
        isAuthorizedCaller[caller] = false;
        emit CallerRevoked(caller);
    }

    /// @notice Add an authorized relayer
    function addRelayer(address relayer) external onlyOwner {
        if (relayer == address(0)) revert OnlyAuthorizedRelayer();
        if (isAuthorizedRelayer[relayer]) revert AlreadyAuthorized();
        isAuthorizedRelayer[relayer] = true;
        unchecked { relayerCount++; }
        emit RelayerAuthorized(relayer);
    }

    /// @notice Remove a relayer (cannot remove last one)
    function removeRelayer(address relayer) external onlyOwner {
        if (!isAuthorizedRelayer[relayer]) revert NotAuthorized();
        if (relayerCount <= 1) revert CannotRemoveLastRelayer();
        isAuthorizedRelayer[relayer] = false;
        unchecked { relayerCount--; }
        emit RelayerRevoked(relayer);
    }

    /// @notice Set the beneficiary vault address for a specific parachain
    /// @param paraId The parachain ID
    /// @param beneficiary AccountId32 or padded address of the vault on the parachain
    function setParachainBeneficiary(uint32 paraId, bytes32 beneficiary) external onlyOwner {
        if (paraId == 0) revert InvalidParachain();
        if (beneficiary == bytes32(0)) revert InvalidBeneficiary();
        parachainBeneficiary[paraId] = beneficiary;
        emit BeneficiaryConfigured(paraId, beneficiary);
    }

    /// @notice Configure XCM weight parameters for a parachain
    /// @param paraId The parachain ID
    /// @param weightRefTime Compute weight limit
    /// @param weightProofSize Proof size weight limit
    function setRouteConfig(
        uint32 paraId,
        uint64 weightRefTime,
        uint64 weightProofSize
    ) external onlyOwner {
        if (paraId == 0) revert InvalidParachain();
        parachainRouteConfig[paraId] = XcmTypes.XcmRoute({
            paraId: paraId,
            beneficiary: parachainBeneficiary[paraId],
            weightRefTime: weightRefTime,
            weightProofSize: weightProofSize
        });
        emit RouteConfigured(paraId, weightRefTime, weightProofSize);
    }

    /// @notice Manually update precompile availability
    function refreshPrecompileStatus() external onlyOwner {
        xcmPrecompileAvailable = _hasCode(XCM_PRECOMPILE);
        emit PrecompileStatusUpdated(xcmPrecompileAvailable);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Set the PVM CryptoRegistry contract
    /// @param _cryptoRegistry Address of the deployed CryptoRegistry
    function setCryptoRegistry(address _cryptoRegistry) external onlyOwner {
        require(_cryptoRegistry != address(0), "Invalid registry");
        cryptoRegistry = ICryptoRegistry(_cryptoRegistry);
        emit CryptoRegistrySet(_cryptoRegistry);
    }

    /// @notice Add a trusted validator public key for signed confirmations
    /// @param pubkey Sr25519/Ed25519 public key of the validator
    function addTrustedValidator(bytes32 pubkey) external onlyOwner {
        if (pubkey == bytes32(0)) revert InvalidValidatorPubKey();
        isTrustedValidator[pubkey] = true;
        emit ValidatorTrusted(pubkey);
    }

    /// @notice Remove a trusted validator public key
    function removeTrustedValidator(bytes32 pubkey) external onlyOwner {
        isTrustedValidator[pubkey] = false;
        emit ValidatorRevoked(pubkey);
    }

    // =========================================================================
    // Internal — XCM Precompile Dispatch
    // =========================================================================

    /// @notice Attempt to dispatch via the XCM precompile
    /// @dev Returns false if the call fails (precompile not available, etc.)
    function _dispatchViaPrecompile(
        uint32 paraId,
        bytes32 beneficiary,
        uint256 amount
    ) internal returns (bool success) {
        // Build XCM params in a sub-function to avoid stack-too-deep
        (
            IXcmPrecompile.Multilocation memory dest,
            IXcmPrecompile.Multilocation memory ben,
            IXcmPrecompile.WeightV2 memory weight
        ) = _buildXcmParams(paraId, beneficiary);

        // Try the precompile call (low-level to handle reverts gracefully)
        try IXcmPrecompile(XCM_PRECOMPILE).transferNative{value: amount}(
            dest, ben, amount, weight
        ) returns (bool result) {
            success = result;
        } catch {
            success = false;
        }
    }

    /// @notice Build XCM Multilocation and weight params (separated to avoid stack-too-deep)
    function _buildXcmParams(
        uint32 paraId,
        bytes32 beneficiary
    ) internal view returns (
        IXcmPrecompile.Multilocation memory dest,
        IXcmPrecompile.Multilocation memory ben,
        IXcmPrecompile.WeightV2 memory weight
    ) {
        // Build destination: { parents: 1, interior: [Parachain(paraId)] }
        (uint8 destParents, bytes[] memory destInterior) = XcmBuilder.buildParachainDest(paraId);
        dest = IXcmPrecompile.Multilocation({ parents: destParents, interior: destInterior });

        // Build beneficiary: { parents: 0, interior: [AccountId32(beneficiary)] }
        (uint8 benParents, bytes[] memory benInterior) = XcmBuilder.buildSubstrateBeneficiary(beneficiary);
        ben = IXcmPrecompile.Multilocation({ parents: benParents, interior: benInterior });

        // Get weight from config or use defaults
        XcmTypes.XcmRoute storage config = parachainRouteConfig[paraId];
        uint64 refTime = config.weightRefTime > 0 ? config.weightRefTime : DEFAULT_REF_TIME;
        uint64 proofSize = config.weightProofSize > 0 ? config.weightProofSize : DEFAULT_PROOF_SIZE;
        weight = IXcmPrecompile.WeightV2({ refTime: refTime, proofSize: proofSize });
    }

    /// @notice Check if an address has deployed code
    function _hasCode(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    // =========================================================================
    // Receive — Accept return transfers from XCM
    // =========================================================================

    /// @notice Accept native token returns from XCM or relayer
    /// @dev Funds come back when users withdraw from parachain yield sources
    receive() external payable {}
}
