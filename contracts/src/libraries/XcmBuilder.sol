// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {XcmTypes} from "./XcmTypes.sol";

/// @title XcmBuilder
/// @author Omni-Shield Team
/// @notice Library for building XCM Multilocation junctions and messages
/// @dev Encodes Polkadot-native XCM v3 types into bytes that can be passed
///      to the XCM precompile. Uses SCALE-compatible encoding where needed.
///
/// Junction encoding (SCALE-compatible):
///   Parachain(id)     → [0x00, id_le_bytes_4]
///   AccountKey20(addr) → [0x03, network_byte, addr_20_bytes]
///   AccountId32(id)   → [0x01, network_byte, id_32_bytes]
///   GeneralIndex(idx) → [0x05, idx_compact]
///   PalletInstance(n) → [0x04, n]
library XcmBuilder {
    // =========================================================================
    // Junction Builders
    // =========================================================================

    /// @notice Encode a Parachain junction
    /// @param paraId The parachain ID (e.g., 2030 for Bifrost)
    /// @return junction Encoded junction bytes
    function parachain(uint32 paraId) internal pure returns (bytes memory junction) {
        junction = abi.encodePacked(
            XcmTypes.JUNCTION_PARACHAIN,
            _toLittleEndian32(paraId)
        );
    }

    /// @notice Encode an AccountKey20 junction (for EVM-compatible chains)
    /// @param addr The 20-byte EVM address
    /// @return junction Encoded junction bytes
    function accountKey20(address addr) internal pure returns (bytes memory junction) {
        junction = abi.encodePacked(
            XcmTypes.JUNCTION_ACCOUNT_KEY_20,
            XcmTypes.NETWORK_ANY,
            addr
        );
    }

    /// @notice Encode an AccountId32 junction (for Substrate chains)
    /// @param accountId The 32-byte Substrate account ID
    /// @return junction Encoded junction bytes
    function accountId32(bytes32 accountId) internal pure returns (bytes memory junction) {
        junction = abi.encodePacked(
            XcmTypes.JUNCTION_ACCOUNT_ID_32,
            XcmTypes.NETWORK_ANY,
            accountId
        );
    }

    /// @notice Encode a PalletInstance junction
    /// @param palletIndex The pallet index on the destination
    /// @return junction Encoded junction bytes
    function palletInstance(uint8 palletIndex) internal pure returns (bytes memory junction) {
        junction = abi.encodePacked(
            XcmTypes.JUNCTION_PALLET_INSTANCE,
            palletIndex
        );
    }

    /// @notice Encode a GeneralIndex junction
    /// @param index The general index value
    /// @return junction Encoded junction bytes
    function generalIndex(uint128 index) internal pure returns (bytes memory junction) {
        junction = abi.encodePacked(
            XcmTypes.JUNCTION_GENERAL_INDEX,
            index
        );
    }

    // =========================================================================
    // Multilocation Builders
    // =========================================================================

    /// @notice Build a parachain destination Multilocation
    /// @dev Multilocation { parents: 1, interior: X1(Parachain(paraId)) }
    ///      This routes via the relay chain to a sibling parachain
    /// @param paraId Destination parachain ID
    /// @return parents Number of parent hops (1 = via relay)
    /// @return interior Array of junction bytes
    function buildParachainDest(uint32 paraId)
        internal
        pure
        returns (uint8 parents, bytes[] memory interior)
    {
        parents = 1; // Go up to relay chain
        interior = new bytes[](1);
        interior[0] = parachain(paraId);
    }

    /// @notice Build a beneficiary Multilocation for an EVM address on a parachain
    /// @dev Multilocation { parents: 0, interior: X1(AccountKey20(addr)) }
    /// @param addr EVM address of the beneficiary
    /// @return parents Always 0 (local to destination)
    /// @return interior Array of junction bytes
    function buildEvmBeneficiary(address addr)
        internal
        pure
        returns (uint8 parents, bytes[] memory interior)
    {
        parents = 0;
        interior = new bytes[](1);
        interior[0] = accountKey20(addr);
    }

    /// @notice Build a beneficiary Multilocation for a Substrate AccountId32
    /// @dev Multilocation { parents: 0, interior: X1(AccountId32(id)) }
    /// @param accountId 32-byte Substrate account
    /// @return parents Always 0
    /// @return interior Array of junction bytes
    function buildSubstrateBeneficiary(bytes32 accountId)
        internal
        pure
        returns (uint8 parents, bytes[] memory interior)
    {
        parents = 0;
        interior = new bytes[](1);
        interior[0] = accountId32(accountId);
    }

    // =========================================================================
    // Message Hash Builder
    // =========================================================================

    /// @notice Compute a unique hash for an XCM dispatch
    /// @dev Used to track and identify individual XCM messages
    /// @param routeId YieldRouter route ID
    /// @param paraId Destination parachain
    /// @param amount Amount being dispatched
    /// @param beneficiary Beneficiary address/account
    /// @param nonce Unique nonce to prevent hash collisions
    /// @return messageHash The computed XCM message hash
    function computeMessageHash(
        uint256 routeId,
        uint32 paraId,
        uint256 amount,
        bytes32 beneficiary,
        uint256 nonce
    ) internal pure returns (bytes32 messageHash) {
        messageHash = keccak256(
            abi.encodePacked(
                "OmniShield::XCM::v1",
                routeId,
                paraId,
                amount,
                beneficiary,
                nonce
            )
        );
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// @notice Convert uint32 to little-endian bytes4 (SCALE encoding)
    function _toLittleEndian32(uint32 value) internal pure returns (bytes4) {
        return bytes4(
            bytes4(uint32(value & 0xFF) << 24) |
            bytes4(uint32((value >> 8) & 0xFF) << 16) |
            bytes4(uint32((value >> 16) & 0xFF) << 8) |
            bytes4(uint32((value >> 24) & 0xFF))
        );
    }
}
