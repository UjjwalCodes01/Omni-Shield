# Omni-Shield Deployment Guide for Track 2

> **For the deploying agent**: This document explains all changes made and provides step-by-step deployment instructions for the Polkadot Solidity Hackathon Track 2 submission.

---

## 📋 Summary of Changes Made

### What Was Built (Phases 0-5)

| Phase | Description | Status |
|-------|-------------|--------|
| **Phase 0** | Precompile diagnostic & RPC verification | ✅ Complete |
| **Phase 1** | Blake2b Integration (Substrate-native hashing) | ✅ Complete |
| **Phase 2** | Precompile-Ready Architecture (Sr25519/Ed25519/XCM) | ✅ Complete |
| **Phase 3** | BN128 Pedersen Commitments (Privacy) | ✅ Complete |
| **Phase 4** | Frontend enhancements (Track 2 demo) | ✅ Complete |
| **Phase 5** | Documentation & submission prep | ✅ Complete |

---

## 🆕 New Files Created

### Smart Contract Libraries (Must Deploy)

```
contracts/src/libraries/
├── PvmBlake2.sol          # Blake2b precompile wrapper (Phase 1)
├── BN128Stealth.sol       # Pedersen commitments (Phase 3)
├── SubstrateCompat.sol    # Substrate compatibility helpers (Phase 1)
└── PvmVerifier.sol        # Enhanced with XCM_DISPATCH (Phase 2)
```

### Interfaces (No deployment needed - used by other contracts)

```
contracts/src/interfaces/
├── IPolkadotPrecompiles.sol  # Full precompile specs (Phase 2) - NEW
└── ICryptoRegistry.sol       # Updated with new functions
```

### Test Files (Run before deployment)

```
contracts/test/
├── Blake2bIntegration.t.sol      # 50+ tests (Phase 1) - NEW
├── PrecompileArchitecture.t.sol  # 25+ tests (Phase 2) - NEW
└── BN128Stealth.t.sol           # 30+ tests (Phase 3) - NEW
```

---

## 📝 Files Modified

### 1. `contracts/src/CryptoRegistry.sol`

**Changes Made**:
- Added import for `IPolkadotPrecompiles.sol`
- Added `xcmDispatchAvailable` state variable
- Added `getPolkadotFeatureStatus()` function
- Added `isXcmDispatchAvailable()` function
- Added `getPrecompileAddresses()` function
- Updated `_detectPrecompiles()` to detect XCM dispatch

**Key New Functions**:
```solidity
function isXcmDispatchAvailable() external view returns (bool);
function getPolkadotFeatureStatus() external view returns (
    PrecompileFeatureStatus sr25519Status,
    PrecompileFeatureStatus ed25519Status,
    PrecompileFeatureStatus xcmStatus,
    PrecompileFeatureStatus assetsStatus
);
function getPrecompileAddresses() external pure returns (
    address sr25519Addr,    // 0x0403
    address ed25519Addr,    // 0x0402
    address xcmAddr,        // 0x0816
    address assetsAddr      // 0x0806
);
```

### 2. `contracts/src/libraries/PvmBlake2.sol`

**Changes Made**:
- Added comprehensive Track 2 documentation header
- Added `blake2b128()` for Substrate storage keys
- Added `blake2b160()` for Substrate address format
- Added `computeSubstrateAccountId()` for account derivation
- Added `blake2b128Concat()` for storage key format
- Added `hashScaleData()` for SCALE-encoded data
- Added `hashXcmMessage()` for XCM message hashing
- Added `hashMerkleNode()` for merkle proofs

### 3. `contracts/src/libraries/PvmVerifier.sol`

**Changes Made**:
- Added comprehensive Track 2 documentation header
- Made `ED25519_VERIFY` and `SR25519_VERIFY` public constants
- Added `XCM_DISPATCH` constant (0x0816)
- Added `isXcmDispatchAvailable()` function
- Added precompile readiness matrix in comments

### 4. `contracts/src/interfaces/ICryptoRegistry.sol`

**Changes Made**:
- Added `isXcmDispatchAvailable()` function signature
- Added `getPolkadotFeatureStatus()` function signature
- Added `getPrecompileAddresses()` function signature
- Added `refreshPrecompileStatus()` function signature

### 5. `contracts/src/interfaces/IStealthPayment.sol`

**Changes Made**:
- Added `AmountCommitmentCreated` event for Pedersen commitments
- Added `CommitmentVerified` event for withdrawal verification

---

## 🚀 Deployment Instructions

### Prerequisites

```bash
# Ensure Foundry is installed
forge --version

# Required: Foundry 0.2.0+
# Chain: Polkadot Hub Testnet (420420417)
# RPC: https://eth-rpc-testnet.polkadot.io/
```

### Step 1: Build & Test Contracts

```bash
cd contracts

# Install dependencies
forge install

# Build all contracts
forge build

# Run ALL tests (must pass before deployment)
forge test -vv

# Run Track 2 specific tests
forge test --match-path test/Blake2bIntegration.t.sol -vv
forge test --match-path test/PrecompileArchitecture.t.sol -vv
forge test --match-path test/BN128Stealth.t.sol -vv
```

**Expected**: 170+ tests, all passing ✅

### Step 2: Deploy CryptoRegistry (CRITICAL)

The CryptoRegistry is the **core Track 2 contract**. It must be redeployed with the new functions.

```bash
# Set environment
export RPC_URL="https://eth-rpc-testnet.polkadot.io"
export PRIVATE_KEY="your_deployer_private_key"

# Deploy CryptoRegistry
forge create src/CryptoRegistry.sol:CryptoRegistry \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast

# Note the deployed address!
# Example: 0x237259A349F258eD5d561F90dcb701f4371169B3
```

### Step 3: Verify CryptoRegistry Functions

After deployment, verify the new functions work:

```bash
# Test blake2fAvailable
cast call <NEW_CRYPTO_REGISTRY> "blake2fAvailable()" --rpc-url $RPC_URL
# Expected: 0x0000000000000000000000000000000000000000000000000000000000000001 (true)

# Test bn128Available
cast call <NEW_CRYPTO_REGISTRY> "bn128Available()" --rpc-url $RPC_URL
# Expected: 0x0000000000000000000000000000000000000000000000000000000000000001 (true)

# Test isXcmDispatchAvailable
cast call <NEW_CRYPTO_REGISTRY> "isXcmDispatchAvailable()" --rpc-url $RPC_URL
# Expected: 0x0000000000000000000000000000000000000000000000000000000000000000 (false - not deployed yet)

# Test blake2b256
cast call <NEW_CRYPTO_REGISTRY> "blake2b256(bytes)" "0x68656c6c6f" --rpc-url $RPC_URL
# Expected: 0x324dcf027dd4a30a932c441f365a25e86b173defa4b8e58948253471b81b72cf
```

### Step 4: Update Dependent Contracts

If redeploying, update these contracts to point to new CryptoRegistry:

```bash
# StealthPayment - set new CryptoRegistry
cast send <STEALTH_PAYMENT> "setCryptoRegistry(address)" <NEW_CRYPTO_REGISTRY> \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# StealthVault (if it uses CryptoRegistry)
# XcmRouter (if it uses CryptoRegistry)
```

### Step 5: Update Frontend Configuration

After deployment, update the contract address in frontend:

**File**: `frontend/app/lib/stealth.ts`

```typescript
export const CONTRACT_ADDRESSES = {
  cryptoRegistry: "0xNEW_ADDRESS_HERE",  // <-- Update this
  stealthPayment: "0x98DB1edC0ED10888d559C641F709A364818B0167",
  stealthVault: "0x5290EC1961854B8a45346f74BeF775E51d4Ba076",
  escrow: "0xFa10b866e5B4a3BDD2d0a978FCB5cAbb334372BE",
  yieldRouter: "0xa4B00C51eD83c7a9E1F646E9C0329F4E61f651F1",
  xcmRouter: "0x2BA3337232F5b1eA4b14f3ca0121C3272c25Bb4E",
  omniShieldHub: "0xCe7917f133B5f31807cC839DCC44f836D8ca7142",
};
```

### Step 6: Verify Frontend

```bash
cd frontend
npm install
npm run build  # Must succeed with no errors
npm run dev    # Start and test at http://localhost:3000
```

**Test Flow**:
1. Go to `/pvm` page
2. Verify precompile status shows:
   - Blake2F: ✅ Available
   - BN128: ✅ Available
   - Sr25519/Ed25519/XCM: ❌ Unavailable (expected)
3. Test Blake2b Hasher - type text, get hash
4. Test BN128 operations work (if computePedersenCommitment is deployed)

---

## 🔧 Contract Architecture

### Dependency Graph

```
                    ┌─────────────────────┐
                    │   CryptoRegistry    │ ← Core Track 2 Contract
                    │  (precompile hub)   │
                    └─────────┬───────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
┌───────────────┐   ┌─────────────────┐   ┌─────────────────┐
│  PvmBlake2    │   │  PvmVerifier    │   │  BN128Stealth   │
│  (library)    │   │  (library)      │   │  (library)      │
│               │   │                 │   │                 │
│ • blake2b256  │   │ • verifySr25519 │   │ • computeCommit │
│ • blake2b128  │   │ • verifyEd25519 │   │ • pointMul      │
│ • accountId   │   │ • bn128Mul      │   │ • pointAdd      │
│ • storageKey  │   │ • isSr25519Avl  │   │ • verifyCommit  │
└───────────────┘   └─────────────────┘   └─────────────────┘
        │                     │                     │
        └─────────────────────┼─────────────────────┘
                              │
                    ┌─────────┴─────────┐
                    │                   │
                    ▼                   ▼
            ┌───────────────┐   ┌───────────────┐
            │StealthPayment │   │   XcmRouter   │
            │(uses Blake2b) │   │(uses XCM disp)│
            └───────────────┘   └───────────────┘
```

### Precompile Addresses Used

| Precompile | Address | Status | Used By |
|------------|---------|--------|---------|
| Blake2F | 0x09 | ✅ Working | PvmBlake2.sol |
| BN128 Add | 0x06 | ✅ Working | PvmVerifier.sol, BN128Stealth.sol |
| BN128 Mul | 0x07 | ✅ Working | PvmVerifier.sol, BN128Stealth.sol |
| BN128 Pairing | 0x08 | ✅ Working | PvmVerifier.sol |
| Sr25519 Verify | 0x0403 | ❌ Not deployed | PvmVerifier.sol (ready) |
| Ed25519 Verify | 0x0402 | ❌ Not deployed | PvmVerifier.sol (ready) |
| XCM Dispatch | 0x0816 | ❌ Not deployed | XcmRouter.sol (ready) |
| Assets | 0x0806 | ❌ Not deployed | IPolkadotPrecompiles.sol (ready) |

---

## 🎯 Track 2 Requirements Verification

After deployment, verify these Track 2 requirements:

### 1. PVM-experiments (Call Rust/C++ from Solidity)

```bash
# Verify Blake2b works
cast call <CRYPTO_REGISTRY> "blake2b256(bytes)" "0x48656c6c6f" --rpc-url $RPC_URL
# Should return: Blake2b hash (not keccak!)

# Verify BN128 works
cast call <CRYPTO_REGISTRY> "bn128ScalarMul(uint256,uint256,uint256)" 1 2 5 --rpc-url $RPC_URL
# Should return: 5*G point coordinates
```

### 2. Polkadot Native Assets

```bash
# Verify interface exists
cast call <CRYPTO_REGISTRY> "getPrecompileAddresses()" --rpc-url $RPC_URL
# Should include 0x0806 (Assets precompile address)
```

### 3. Polkadot Precompiles

```bash
# Verify detection works
cast call <CRYPTO_REGISTRY> "getPolkadotFeatureStatus()" --rpc-url $RPC_URL
# Should return status enum values for Sr25519, Ed25519, XCM, Assets
```

---

## 📁 Files to NOT Modify

These files are already correct and deployed:

- `contracts/src/OmniShieldEscrow.sol` - Working
- `contracts/src/StealthPayment.sol` - Working
- `contracts/src/StealthVault.sol` - Working
- `contracts/src/YieldRouter.sol` - Working
- `contracts/src/XcmRouter.sol` - Working
- `contracts/src/OmniShieldHub.sol` - Working

---

## 🧪 Test Commands Quick Reference

```bash
# Full test suite
forge test -vv

# Track 2 specific
forge test --match-path test/Blake2bIntegration.t.sol -vv
forge test --match-path test/PrecompileArchitecture.t.sol -vv
forge test --match-path test/BN128Stealth.t.sol -vv

# Gas report
forge test --gas-report

# Single test
forge test --match-test test_blake2b256_helloWorld -vv
```

---

## 🔍 Troubleshooting

### "Blake2fNotAvailable" Error

The deployed CryptoRegistry might have blake2fAvailable = false. This shouldn't happen on Polkadot Hub. Check:

```bash
cast call <CRYPTO_REGISTRY> "blake2fAvailable()" --rpc-url $RPC_URL
```

If false, the detection logic might have failed during constructor. Redeploy.

### "Function not found" Error

The frontend ABI might not match deployed contract. Ensure:
1. Contract was rebuilt with `forge build`
2. Same compiler version used
3. Frontend ABI in `contracts.ts` matches actual contract

### "Precompile call failed"

Standard EVM precompiles (0x06-0x09) work but have no code. The test scripts check via actual calls, not extcodesize.

### Frontend shows "Unavailable" for Blake2f/BN128

1. Check RPC URL is correct: `https://eth-rpc-testnet.polkadot.io`
2. Check contract address in `stealth.ts` is correct
3. Check browser console for errors

---

## ✅ Deployment Checklist

```
[ ] forge build succeeds
[ ] forge test passes (170+ tests)
[ ] CryptoRegistry deployed
[ ] blake2fAvailable() returns true
[ ] bn128Available() returns true
[ ] blake2b256() returns correct hash
[ ] bn128ScalarMul() returns correct point
[ ] Frontend CONTRACT_ADDRESSES updated
[ ] Frontend npm run build succeeds
[ ] Frontend /pvm page shows correct status
[ ] Blake2b Hasher demo works
[ ] README.md has correct contract addresses
```

---

## 📧 Contact

If deployment issues occur:
1. Check Polkadot Hub testnet status
2. Verify RPC endpoint is responding
3. Check gas prices and account balance
4. Review error messages in transaction receipts

---

**Good luck with deployment! 🚀**

*This guide was created for Omni-Shield Track 2 submission*
