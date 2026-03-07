// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IXcmPrecompile
/// @author Omni-Shield Team
/// @notice Interface for the Polkadot Hub XCM precompile at 0x0000000000000000000000000000000000000816
/// @dev On Polkadot Hub (Asset Hub), pallet-xcm exposes a precompile that allows
///      EVM contracts to dispatch XCM messages to other parachains.
///
///      The precompile encodes Multilocation and weight parameters into the
///      standard XCM v3 format used by Polkadot Relay Chain.
///
///      Multilocation encoding:
///        - parents: uint8 (0 = sibling, 1 = via relay chain)
///        - interior: bytes[] (junction array: Parachain(id), AccountId32, etc.)
///
///      Reference:
///        - https://docs.polkadot.network/develop/interoperability/intro-to-xcm/
///        - https://github.com/polkadot-fellows/runtimes
interface IXcmPrecompile {
    // =========================================================================
    // Structs (ABI-compatible XCM v3 types)
    // =========================================================================

    /// @notice XCM Multilocation — identifies a consensus entity in Polkadot
    /// @param parents Number of parent hops (0 = local, 1 = relay chain)
    /// @param interior Encoded junction array (Parachain, AccountKey20, etc.)
    struct Multilocation {
        uint8 parents;
        bytes[] interior;
    }

    /// @notice Weight limit for XCM execution on the destination chain
    /// @param refTime Reference time weight (compute)
    /// @param proofSize Proof size weight (storage proof)
    struct WeightV2 {
        uint64 refTime;
        uint64 proofSize;
    }

    // =========================================================================
    // Functions
    // =========================================================================

    /// @notice Transfer native asset to a destination via XCM
    /// @dev Dispatches a reserve_transfer_assets XCM to move native DOT
    ///      to a parachain destination. The asset stays as a reserve on
    ///      Asset Hub while a derivative is minted on the destination.
    /// @param dest Multilocation of the destination parachain
    /// @param beneficiary Multilocation of the beneficiary on the destination
    /// @param amount Amount of native token to transfer (in Planck)
    /// @param weight Execution weight limit on the destination chain
    /// @return success Whether the XCM dispatch was successful
    function transferNative(
        Multilocation calldata dest,
        Multilocation calldata beneficiary,
        uint256 amount,
        WeightV2 calldata weight
    ) external payable returns (bool success);

    /// @notice Transfer a multi-asset to a destination via XCM
    /// @dev For transferring non-native assets (e.g., USDT, USDC on Asset Hub)
    /// @param asset Multilocation identifying the asset
    /// @param dest Multilocation of the destination parachain
    /// @param beneficiary Multilocation of the beneficiary
    /// @param amount Amount to transfer
    /// @param weight Execution weight limit
    /// @return success Whether the dispatch succeeded
    function transferMultiAsset(
        Multilocation calldata asset,
        Multilocation calldata dest,
        Multilocation calldata beneficiary,
        uint256 amount,
        WeightV2 calldata weight
    ) external returns (bool success);

    /// @notice Send arbitrary XCM instructions to a destination
    /// @dev Low-level: sends raw XCM instruction bytes. Use for complex
    ///      cross-chain operations (Transact, ExchangeAsset, etc.)
    /// @param dest Multilocation of the destination
    /// @param message Encoded XCM instruction bytes (SCALE-encoded)
    /// @return success Whether the message was dispatched
    function sendXcm(
        Multilocation calldata dest,
        bytes calldata message
    ) external returns (bool success);
}
