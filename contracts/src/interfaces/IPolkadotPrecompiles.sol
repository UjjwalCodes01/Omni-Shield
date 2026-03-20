// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPolkadotPrecompiles
/// @author Omni-Shield Team
/// @notice Interface definitions for Polkadot Hub precompiles
/// @dev ╔═══════════════════════════════════════════════════════════════════════════╗
///      ║                    TRACK 2: POLKADOT PVM INTEGRATION                      ║
///      ╠═══════════════════════════════════════════════════════════════════════════╣
///      ║  This file documents the full specification of Polkadot-specific          ║
///      ║  precompiles. These interfaces show that our code is READY for when       ║
///      ║  these precompiles are deployed on Polkadot Hub.                          ║
///      ║                                                                           ║
///      ║  References:                                                              ║
///      ║  • Frontier EVM: https://github.com/polkadot-evm/frontier                ║
///      ║  • Moonbeam precompiles: https://docs.moonbeam.network/builders/         ║
///      ║  • Polkadot SDK: https://github.com/paritytech/polkadot-sdk              ║
///      ╚═══════════════════════════════════════════════════════════════════════════╝

// =============================================================================
// Sr25519 Signature Verification (Address: 0x0403)
// =============================================================================

/// @title ISr25519Verify
/// @notice Interface for Sr25519 signature verification precompile
/// @dev Polkadot's primary signature scheme using Schnorr signatures on Ristretto255
///
///      Input Layout (staticcall data):
///      ┌─────────────────────────────────────────────────────────────────┐
///      │ Offset │ Size    │ Field          │ Description                │
///      ├────────┼─────────┼────────────────┼────────────────────────────┤
///      │ 0      │ 32      │ public_key     │ Compressed Ristretto point │
///      │ 32     │ 64      │ signature      │ R (32) || s (32)           │
///      │ 96     │ variable│ message        │ Message bytes to verify    │
///      └────────┴─────────┴────────────────┴────────────────────────────┘
///
///      Output: 32 bytes (uint256)
///      - 1 = signature valid
///      - 0 = signature invalid
///
///      Gas cost: ~3,150 (Frontier default)
interface ISr25519Verify {
    /// @notice Verify an sr25519 signature
    /// @param publicKey 32-byte sr25519 public key (compressed Ristretto255 point)
    /// @param signature 64-byte signature (R || s)
    /// @param message Message that was signed
    /// @return valid 1 if valid, 0 if invalid
    function verify(
        bytes32 publicKey,
        bytes calldata signature,
        bytes calldata message
    ) external view returns (uint256 valid);
}

// =============================================================================
// Ed25519 Signature Verification (Address: 0x0402)
// =============================================================================

/// @title IEd25519Verify
/// @notice Interface for Ed25519 signature verification precompile
/// @dev EdDSA signatures on Curve25519, used by some validators and bridges
///
///      Input Layout (staticcall data):
///      ┌─────────────────────────────────────────────────────────────────┐
///      │ Offset │ Size    │ Field          │ Description                │
///      ├────────┼─────────┼────────────────┼────────────────────────────┤
///      │ 0      │ 32      │ signature_r    │ R component (Edwards pt)   │
///      │ 32     │ 32      │ signature_s    │ S component (scalar)       │
///      │ 64     │ 32      │ public_key     │ 32-byte Ed25519 pubkey     │
///      │ 96     │ variable│ message        │ Message bytes to verify    │
///      └────────┴─────────┴────────────────┴────────────────────────────┘
///
///      Output: 32 bytes (uint256)
///      - 1 = signature valid
///      - 0 = signature invalid
///
///      Gas cost: ~3,000 (Frontier default)
interface IEd25519Verify {
    /// @notice Verify an ed25519 signature
    /// @param signatureR R component of signature (32 bytes)
    /// @param signatureS S component of signature (32 bytes)
    /// @param publicKey 32-byte ed25519 public key
    /// @param message Message that was signed
    /// @return valid 1 if valid, 0 if invalid
    function verify(
        bytes32 signatureR,
        bytes32 signatureS,
        bytes32 publicKey,
        bytes calldata message
    ) external view returns (uint256 valid);
}

// =============================================================================
// XCM Dispatch (Address: 0x0816)
// =============================================================================

/// @title IXcmDispatch
/// @notice Interface for XCM cross-chain message dispatch precompile
/// @dev Enables EVM contracts to send XCM messages to other parachains
///
///      This precompile provides access to pallet-xcm functionality:
///      - reserve_transfer_assets: Transfer assets with reserve semantics
///      - teleport_assets: Teleport assets (for trusted chains)
///      - send: Generic XCM message sending
///
///      MultiLocation Encoding (SCALE):
///      ┌─────────────────────────────────────────────────────────────────┐
///      │ Field    │ Type        │ Description                           │
///      ├──────────┼─────────────┼───────────────────────────────────────┤
///      │ parents  │ uint8       │ Number of parent junctions to ascend  │
///      │ interior │ Junctions   │ Sequence of junction identifiers      │
///      └──────────┴─────────────┴───────────────────────────────────────┘
///
///      Junction Types:
///      - Parachain(uint32): Target a specific parachain
///      - AccountId32 { network, id }: Target an account
///      - PalletInstance(uint8): Target a specific pallet
///      - GeneralIndex(uint128): Generic index
///      - GeneralKey { length, data }: Generic key
interface IXcmDispatch {
    /// @notice Transfer native assets to another chain
    /// @param dest Destination multilocation (SCALE encoded)
    /// @param beneficiary Recipient multilocation (SCALE encoded)
    /// @param amount Amount of native token to transfer
    /// @param weight Maximum weight for execution
    /// @return success True if dispatch succeeded
    function transferNative(
        bytes calldata dest,
        bytes calldata beneficiary,
        uint256 amount,
        uint64 weight
    ) external payable returns (bool success);

    /// @notice Transfer ERC20 assets to another chain
    /// @param dest Destination multilocation
    /// @param beneficiary Recipient multilocation
    /// @param asset Asset multilocation
    /// @param amount Amount to transfer
    /// @param weight Maximum weight
    /// @return success True if dispatch succeeded
    function transferAsset(
        bytes calldata dest,
        bytes calldata beneficiary,
        bytes calldata asset,
        uint256 amount,
        uint64 weight
    ) external returns (bool success);

    /// @notice Send a generic XCM message
    /// @param dest Destination multilocation
    /// @param message Encoded XCM message
    /// @return success True if dispatch succeeded
    /// @return messageHash Hash of the sent message
    function send(
        bytes calldata dest,
        bytes calldata message
    ) external returns (bool success, bytes32 messageHash);
}

// =============================================================================
// Assets Precompile (Address: 0x0806) - Polkadot Native Assets
// =============================================================================

/// @title IPolkadotAssets
/// @notice Interface for Polkadot native assets precompile
/// @dev Provides access to pallet-assets for native Polkadot tokens
///
///      Common Asset IDs on Asset Hub:
///      - 1984: USDT
///      - 1337: USDC
///      - Native DOT is handled separately (not an asset ID)
interface IPolkadotAssets {
    /// @notice Get balance of an asset for an account
    /// @param assetId The asset ID
    /// @param account The account address
    /// @return balance The account's balance
    function balanceOf(uint256 assetId, address account) external view returns (uint256 balance);

    /// @notice Transfer assets to another account
    /// @param assetId The asset ID
    /// @param to Recipient address
    /// @param amount Amount to transfer
    /// @return success True if transfer succeeded
    function transfer(uint256 assetId, address to, uint256 amount) external returns (bool success);

    /// @notice Approve spender to transfer assets
    /// @param assetId The asset ID
    /// @param spender Spender address
    /// @param amount Amount to approve
    /// @return success True if approval succeeded
    function approve(uint256 assetId, address spender, uint256 amount) external returns (bool success);

    /// @notice Get allowance for a spender
    /// @param assetId The asset ID
    /// @param owner Owner address
    /// @param spender Spender address
    /// @return remaining Remaining allowance
    function allowance(uint256 assetId, address owner, address spender) external view returns (uint256 remaining);

    /// @notice Get total supply of an asset
    /// @param assetId The asset ID
    /// @return supply Total supply
    function totalSupply(uint256 assetId) external view returns (uint256 supply);

    /// @notice Get asset metadata
    /// @param assetId The asset ID
    /// @return name Asset name
    /// @return symbol Asset symbol
    /// @return decimals Asset decimals
    function metadata(uint256 assetId) external view returns (
        string memory name,
        string memory symbol,
        uint8 decimals
    );
}

// =============================================================================
// Precompile Addresses Constants
// =============================================================================

/// @title PolkadotPrecompileAddresses
/// @notice Central registry of all Polkadot precompile addresses
library PolkadotPrecompileAddresses {
    // Substrate-specific precompiles (Frontier EVM standard)
    address internal constant ED25519_VERIFY = 0x0000000000000000000000000000000000000402;
    address internal constant SR25519_VERIFY = 0x0000000000000000000000000000000000000403;

    // Polkadot Hub specific precompiles
    address internal constant ASSETS = 0x0000000000000000000000000000000000000806;
    address internal constant XCM_DISPATCH = 0x0000000000000000000000000000000000000816;

    // Standard EVM precompiles (available on all EVM chains)
    address internal constant ECRECOVER = 0x0000000000000000000000000000000000000001;
    address internal constant SHA256 = 0x0000000000000000000000000000000000000002;
    address internal constant RIPEMD160 = 0x0000000000000000000000000000000000000003;
    address internal constant IDENTITY = 0x0000000000000000000000000000000000000004;
    address internal constant MODEXP = 0x0000000000000000000000000000000000000005;
    address internal constant BN128_ADD = 0x0000000000000000000000000000000000000006;
    address internal constant BN128_MUL = 0x0000000000000000000000000000000000000007;
    address internal constant BN128_PAIRING = 0x0000000000000000000000000000000000000008;
    address internal constant BLAKE2F = 0x0000000000000000000000000000000000000009;
}

// =============================================================================
// Feature Status Enum
// =============================================================================

/// @title PrecompileStatus
/// @notice Enumeration of precompile availability states
enum PrecompileFeatureStatus {
    NotAvailable,    // Precompile not deployed
    Available,       // Precompile deployed and working
    CodeReady,       // Our code is ready, awaiting precompile deployment
    Deprecated       // Precompile deprecated, should not be used
}

/// @title PolkadotFeatures
/// @notice Helper library for checking Polkadot feature availability
library PolkadotFeatures {
    /// @notice Check if a precompile address has code deployed
    /// @param precompile The precompile address to check
    /// @return hasCode True if code exists at the address
    function isDeployed(address precompile) internal view returns (bool hasCode) {
        uint256 size;
        assembly {
            size := extcodesize(precompile)
        }
        hasCode = size > 0;
    }

    /// @notice Get comprehensive feature status
    /// @return sr25519 Sr25519 verification status
    /// @return ed25519 Ed25519 verification status
    /// @return xcm XCM dispatch status
    /// @return assets Native assets status
    function getFeatureStatus() internal view returns (
        PrecompileFeatureStatus sr25519,
        PrecompileFeatureStatus ed25519,
        PrecompileFeatureStatus xcm,
        PrecompileFeatureStatus assets
    ) {
        sr25519 = isDeployed(PolkadotPrecompileAddresses.SR25519_VERIFY)
            ? PrecompileFeatureStatus.Available
            : PrecompileFeatureStatus.CodeReady;

        ed25519 = isDeployed(PolkadotPrecompileAddresses.ED25519_VERIFY)
            ? PrecompileFeatureStatus.Available
            : PrecompileFeatureStatus.CodeReady;

        xcm = isDeployed(PolkadotPrecompileAddresses.XCM_DISPATCH)
            ? PrecompileFeatureStatus.Available
            : PrecompileFeatureStatus.CodeReady;

        assets = isDeployed(PolkadotPrecompileAddresses.ASSETS)
            ? PrecompileFeatureStatus.Available
            : PrecompileFeatureStatus.CodeReady;
    }
}
