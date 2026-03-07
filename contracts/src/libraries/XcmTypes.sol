// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title XcmTypes
/// @author Omni-Shield Team
/// @notice Library of XCM v3 type definitions used across the protocol
/// @dev These types mirror the Polkadot XCM standard and are used for
///      building cross-chain messages from Solidity contracts.
library XcmTypes {
    // =========================================================================
    // Enums — XCM Junction Types
    // =========================================================================

    /// @notice Junction kind identifiers (mapped to SCALE encoding prefix bytes)
    uint8 internal constant JUNCTION_PARACHAIN = 0x00;
    uint8 internal constant JUNCTION_ACCOUNT_ID_32 = 0x01;
    uint8 internal constant JUNCTION_ACCOUNT_INDEX_64 = 0x02;
    uint8 internal constant JUNCTION_ACCOUNT_KEY_20 = 0x03;
    uint8 internal constant JUNCTION_PALLET_INSTANCE = 0x04;
    uint8 internal constant JUNCTION_GENERAL_INDEX = 0x05;
    uint8 internal constant JUNCTION_GENERAL_KEY = 0x06;

    /// @notice Network ID for junction encoding
    uint8 internal constant NETWORK_ANY = 0x00;
    uint8 internal constant NETWORK_POLKADOT = 0x02;
    uint8 internal constant NETWORK_KUSAMA = 0x03;

    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice Represents a cross-chain route with full XCM metadata
    struct XcmRoute {
        uint32 paraId;           // Destination parachain ID
        bytes32 beneficiary;     // AccountId32 on destination (or EVM address padded)
        uint64 weightRefTime;    // Max compute weight on destination
        uint64 weightProofSize;  // Max proof size on destination
    }

    /// @notice Represents the status of an XCM dispatch
    enum XcmStatus {
        Pending,     // Dispatched, awaiting relay confirmation
        Confirmed,   // Relay chain confirmed delivery
        Failed,      // XCM execution failed on destination
        TimedOut     // No confirmation within timeout window
    }

    /// @notice Full XCM dispatch record for a routed deposit
    struct XcmDispatch {
        uint256 routeId;         // Associated YieldRouter route ID
        uint32 paraId;           // Destination parachain
        uint256 amount;          // Amount dispatched
        XcmStatus status;        // Current dispatch status
        bytes32 xcmMessageHash;  // Hash of the dispatched XCM message
        uint64 dispatchedAt;     // Timestamp of dispatch
        uint64 confirmedAt;      // Timestamp of confirmation (0 if pending)
        uint64 timeoutAt;        // Deadline for confirmation
    }
}
