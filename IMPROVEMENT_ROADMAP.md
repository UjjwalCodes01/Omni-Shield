# Omni-Shield: Track 2 PVM Integration Roadmap

> A step-by-step guide to transform Omni-Shield into a legitimate Polkadot PVM Smart Contract submission

---

## Table of Contents

1. [Current State Analysis](#current-state-analysis)
2. [Track 2 Requirements Gap](#track-2-requirements-gap)
3. [Phase 0: Foundation & Verification](#phase-0-foundation--verification)
4. [Phase 1: Core PVM Integration](#phase-1-core-pvm-integration)
5. [Phase 2: XCM Precompile Integration](#phase-2-xcm-precompile-integration)
6. [Phase 3: Native Asset Support](#phase-3-native-asset-support)
7. [Phase 4: Frontend Polkadot Wallet Integration](#phase-4-frontend-polkadot-wallet-integration)
8. [Phase 5: Backend Improvements](#phase-5-backend-improvements)
9. [Phase 6: Testing & Documentation](#phase-6-testing--documentation)
10. [Risk Mitigation](#risk-mitigation)
11. [File Change Summary](#file-change-summary)
12. [Success Criteria](#success-criteria)

---

## Current State Analysis

### What Exists Today

```
Omni-Shield/
├── contracts/           # Solidity smart contracts (Foundry)
│   ├── src/
│   │   ├── OmniShieldEscrow.sol    ✅ Working EVM escrow
│   │   ├── YieldRouter.sol          ✅ Working yield routing logic
│   │   ├── XcmRouter.sol            ⚠️ XCM logic exists but uses fallbacks
│   │   ├── StealthPayment.sol       ✅ Working stealth payments
│   │   ├── CryptoRegistry.sol       ⚠️ PVM wrappers exist but untested
│   │   └── libraries/
│   │       ├── PvmVerifier.sol      ⚠️ Precompile calls written but unverified
│   │       └── PvmBlake2.sol        ✅ Blake2b works (standard EVM)
│   └── test/                        ⚠️ Tests exist but mock PVM behavior
│
├── backend/             # Node.js relayer service
│   └── src/
│       ├── dispatchMonitor.js       ⚠️ Simulates XCM confirmations
│       ├── yieldOracle.js           ✅ Working APY oracle
│       └── healthMonitor.js         ✅ Working health checks
│
└── frontend/            # Next.js dashboard
    └── app/
        ├── escrow/                   ✅ Working UI
        ├── yield/                    ✅ Working UI
        ├── stealth/                  ✅ Working UI
        └── pvm/                      ⚠️ Shows precompile status only
```

### Code Quality Assessment

| Component | Quality | Track 2 Readiness |
|-----------|---------|-------------------|
| Smart Contracts | 8/10 | 3/10 |
| Backend | 7/10 | 2/10 |
| Frontend | 7/10 | 2/10 |
| Tests | 6/10 | 2/10 |
| Documentation | 7/10 | 4/10 |

### The Core Problem

The project has **excellent scaffolding** for PVM integration, but currently:

1. **Precompile calls are wrapped in graceful fallbacks** - if sr25519/ed25519 isn't available, functions return `false` instead of utilizing the feature
2. **XCM dispatch is event-based** - the backend simulates confirmations instead of using real cross-chain messaging
3. **Native assets not used** - all token handling is generic ERC20, not Polkadot Asset Hub assets
4. **Frontend uses only MetaMask** - no Polkadot.js wallet integration for substrate signatures

---

## Track 2 Requirements Gap

### What Track 2 Expects

| Requirement | Description | Current Status |
|-------------|-------------|----------------|
| **PVM-experiments** | Call Rust/C++ libraries from Solidity | ❌ Code exists but fallbacks used |
| **Polkadot Native Assets** | Use assets from Asset Hub or parachains | ❌ Only generic ERC20 |
| **Polkadot Precompiles** | Use features unique to Polkadot | ❌ Only standard EVM precompiles working |

### The "Ethereum Test"

> *"If your project works identically on Ethereum, it's not a Track 2 project."*

**Current situation:** Omni-Shield would work on Arbitrum, Optimism, or any EVM chain with minimal changes. This disqualifies it from Track 2.

**Goal:** After our improvements, the project should **fail** if deployed to Ethereum because it relies on Polkadot-specific features.

---

## Phase 0: Foundation & Verification

> **Objective:** Understand what actually works on the target chain before writing code

### 0.1 Precompile Availability Check

**What we're doing:** Creating a diagnostic tool to check which PVM precompiles are deployed on the testnet.

**Why this matters:** We cannot write code for features that don't exist. This phase determines our entire strategy.

**Files affected:**
- `test-precompiles.js` (new file at project root)

**Expected outcomes:**
- Know if Sr25519 precompile (0x0403) is available
- Know if Ed25519 precompile (0x0402) is available
- Know if XCM precompile (0x0816) is available
- Know if Assets precompile (0x0806) is available
- Confirm Blake2b (0x09) and BN128 (0x06-0x08) work

**Decision tree after this phase:**

```
Precompile Check Results
│
├─ Sr25519 (0x0403) Available?
│   ├─ YES → Proceed with sr25519 signature features
│   └─ NO  → Skip sr25519, focus on other PVM features
│
├─ XCM (0x0816) Available?
│   ├─ YES → Implement real XCM dispatch
│   └─ NO  → Keep event-based but emphasize Blake2b hashing
│
└─ Assets (0x0806) Available?
    ├─ YES → Add native asset support
    └─ NO  → Continue with wrapped tokens, emphasize other features
```

### 0.2 Environment Setup

**What we're doing:** Ensuring development environment matches testnet configuration.

**Files affected:**
- `contracts/.env.example` (update RPC endpoints)
- `contracts/foundry.toml` (add testnet configuration)

**Dependencies to verify:**
- Foundry version supports Polkadot Hub chain ID
- ethers.js v6 for frontend/backend
- @polkadot/api for wallet integration (to be added)

---

## Phase 1: Core PVM Integration

> **Objective:** Remove fallbacks from PVM code and make precompile calls mandatory

### 1.1 Strict Precompile Mode in CryptoRegistry

**What we're changing:**

Currently, `CryptoRegistry.sol` does this:
```
if (sr25519Available) {
    verify signature
} else {
    return false  ← This is the problem - graceful degradation
}
```

We need:
```
require(sr25519Available, "Sr25519 precompile not available");
verify signature  ← Now it REQUIRES the precompile
```

**Why this matters:** Judges will inspect the code. If they see fallbacks everywhere, they know you're not really using PVM. Making precompiles mandatory proves genuine integration.

**Files affected:**
- `contracts/src/CryptoRegistry.sol`
  - Remove fallback behavior in `verifySr25519Signature()`
  - Remove fallback behavior in `verifyEd25519Signature()`
  - Add explicit revert if precompile unavailable
  - Add a "strict mode" flag that can be toggled for testing vs production

**Risk mitigation:** Add a constructor parameter `bool strictMode` that:
- In production: requires precompiles
- In local testing: allows fallbacks

### 1.2 PvmVerifier Library Hardening

**What we're changing:**

Currently `PvmVerifier.sol` returns `false` on failures. We need it to clearly distinguish between:
1. Signature is invalid (expected, return false)
2. Precompile not available (unexpected, should revert)

**Files affected:**
- `contracts/src/libraries/PvmVerifier.sol`
  - Add explicit precompile existence checks before calls
  - Add custom errors: `PrecompileNotDeployed(address)`
  - Improve return value handling

### 1.3 New Feature: Substrate Wallet Authentication

**What we're adding:**

A completely new authentication path that uses sr25519 signatures from Polkadot wallets. This is the **killer feature** that proves PVM integration.

**Concept:**
```
Traditional (works anywhere):
User signs with MetaMask (ECDSA) → Contract verifies with ecrecover()

Polkadot-native (only works on Polkadot Hub):
User signs with Polkadot.js (sr25519) → Contract verifies with 0x0403 precompile
```

**Files affected:**
- `contracts/src/OmniShieldEscrow.sol`
  - Add `releaseWithSubstrateAuth()` function
  - Add `refundWithSubstrateAuth()` function
  - Add substrate pubkey → EVM address mapping

- `contracts/src/StealthPayment.sol` (already has some of this)
  - Make `sendNativeWithSubstrateAuth()` require precompile
  - Add batch substrate-authenticated payments

**New struct to add:**
```
struct SubstrateAuth {
    bytes32 pubkey;           // sr25519 public key
    uint256 nonce;            // replay protection
    uint256 deadline;         // expiration timestamp
    bytes signature;          // 64-byte sr25519 signature
}
```

---

## Phase 2: XCM Precompile Integration

> **Objective:** Replace simulated XCM with real precompile calls

### 2.1 Understanding Current XCM Flow

```
CURRENT FLOW (Simulated):
┌──────────────┐         ┌──────────────┐         ┌──────────────┐
│   User       │──deposit─▶│ YieldRouter  │──event──▶│   Backend    │
│              │         │              │         │   (Node.js)  │
└──────────────┘         └──────────────┘         └──────┬───────┘
                                                         │ confirms
                                                         ▼
                         ┌──────────────┐         ┌──────────────┐
                         │  XcmRouter   │◀─call───│   Relayer    │
                         │              │         │              │
                         └──────────────┘         └──────────────┘

Problem: The "XCM" is just a relayer calling confirmDispatch()
         No actual cross-chain message is sent
```

### 2.2 Target XCM Flow

```
TARGET FLOW (Real XCM):
┌──────────────┐         ┌──────────────┐         ┌──────────────┐
│   User       │──deposit─▶│ YieldRouter  │─────────▶│  XcmRouter   │
│              │         │              │         │              │
└──────────────┘         └──────────────┘         └──────┬───────┘
                                                         │ calls
                                                         ▼
                         ┌──────────────┐         ┌──────────────┐
                         │   XCM        │◀────────│  Precompile  │
                         │   Message    │         │   0x0816     │
                         └──────┬───────┘         └──────────────┘
                                │ via relay chain
                                ▼
                         ┌──────────────┐
                         │  Destination │
                         │  Parachain   │
                         └──────────────┘
```

### 2.3 XcmRouter Modifications

**What we're changing:**

The XcmRouter currently has a "best effort" approach:
1. Try precompile
2. If fails, emit event for backend
3. Backend simulates confirmation

We need:
1. Require precompile availability (strict mode)
2. Call precompile
3. Revert if precompile call fails
4. Backend only monitors for confirmations (doesn't simulate)

**Files affected:**
- `contracts/src/XcmRouter.sol`
  - Add `strictXcmMode` flag
  - Modify `dispatchToParachain()` to require XCM precompile
  - Remove fallback event-only path in production mode
  - Improve `_dispatchViaPrecompile()` to handle all XCM params correctly
  - Add better error messages for debugging

### 2.4 XcmBuilder Library Enhancement

**What we're changing:**

The `XcmBuilder.sol` library builds XCM multilocations. We need to:
- Verify the encoding matches what substrate expects
- Add more destination types (not just parachains)
- Support XCM versioning (v3, v4)

**Files affected:**
- `contracts/src/libraries/XcmBuilder.sol`
  - Add XCM v3/v4 encoding support
  - Add relay chain destination option
  - Add Asset Hub specific multilocations
  - Better beneficiary encoding options

### 2.5 New: XCM Message Verification

**What we're adding:**

A way to verify that XCM messages match their substrate-side representation using Blake2b hashing.

**Why:** Even if full XCM dispatch doesn't work, we can prove that our contracts compute hashes that match the relay chain. This is still PVM-relevant.

**Files affected:**
- `contracts/src/XcmRouter.sol`
  - Add `verifyXcmMessageHash()` function
  - Compute Blake2b hash of XCM payload
  - Allow external verification of message authenticity

---

## Phase 3: Native Asset Support

> **Objective:** Accept and handle Polkadot-native assets, not just ERC20

### 3.1 Understanding Polkadot Assets

```
POLKADOT ASSET TYPES:

1. DOT (Native)
   - Handled as msg.value in EVM
   - Already supported

2. Asset Hub Assets (Parachain 1000)
   - USDT (Asset ID: 1984)
   - USDC (Asset ID: 1337)
   - Accessed via Assets precompile (0x0806)

3. Parachain Tokens
   - Each parachain has its own tokens
   - Accessed via XCM reserves
```

### 3.2 Assets Precompile Interface

**What we're adding:**

A new interface to interact with Polkadot's native assets.

**Files affected:**
- `contracts/src/interfaces/IAssetsPrecompile.sol` (new file)
  - Define `balanceOf(assetId, account)`
  - Define `transfer(assetId, to, amount)`
  - Define `approve(assetId, spender, amount)`

### 3.3 Asset-Aware Escrow

**What we're changing:**

Currently, escrow supports:
- Native DOT (via msg.value)
- ERC20 tokens (via IERC20)

We need to add:
- Asset Hub assets (via Assets precompile)

**Files affected:**
- `contracts/src/OmniShieldEscrow.sol`
  - Add `AssetType` enum: `{ Native, ERC20, PolkadotAsset }`
  - Add `createAssetEscrow()` for native Polkadot assets
  - Add `releaseAssetEscrow()` to handle asset transfers
  - Update `Escrow` struct to include `assetId` field

### 3.4 Asset-Aware Yield Router

**What we're changing:**

Allow yield routing for native Polkadot assets, not just DOT.

**Files affected:**
- `contracts/src/YieldRouter.sol`
  - Add asset ID parameter to routes
  - Support routing USDT/USDC to yield sources
  - Update APY tracking per asset

### 3.5 Asset-Aware Stealth Payments

**What we're changing:**

Enable private payments using native Polkadot assets.

**Files affected:**
- `contracts/src/StealthPayment.sol`
  - Add `sendAssetToStealth()` for native assets
  - Update balance tracking for asset IDs
  - Update withdrawal functions

---

## Phase 4: Frontend Polkadot Wallet Integration

> **Objective:** Connect Polkadot.js wallets and enable sr25519 signing

### 4.1 Current Frontend State

```
CURRENT:
User → MetaMask (ECDSA) → ethers.js → Contract

PROBLEM:
- Only supports Ethereum-style wallets
- Cannot sign with sr25519
- Cannot prove Polkadot-native integration
```

### 4.2 Target Frontend State

```
TARGET:
User → Polkadot.js Extension (sr25519) → @polkadot/api → Contract
     → MetaMask (ECDSA) ─────────────────────────────────┘

Both paths work, but sr25519 path is Polkadot-exclusive
```

### 4.3 New Dependencies

**What we're adding:**

- `@polkadot/api` - Polkadot API client
- `@polkadot/extension-dapp` - Browser extension integration
- `@polkadot/util-crypto` - Cryptographic utilities

**Files affected:**
- `frontend/package.json` - Add dependencies

### 4.4 Wallet Connection Component

**What we're adding:**

A dual-wallet connection system:
1. MetaMask/EVM wallets (existing)
2. Polkadot.js/Talisman/SubWallet (new)

**Files affected:**
- `frontend/app/components/wallet-provider.tsx`
  - Add Polkadot wallet state
  - Add connection logic for Polkadot extensions
  - Add account selection UI

- `frontend/app/components/polkadot-connect.tsx` (new file)
  - Dedicated Polkadot wallet connection component
  - Account display with ss58 address format
  - Signing helper functions

### 4.5 Substrate Signing UI

**What we're adding:**

UI components for sr25519 signature operations.

**Files affected:**
- `frontend/app/escrow/page.tsx`
  - Add "Release with Polkadot Wallet" button
  - Add signature flow UI
  - Show both EVM and substrate options

- `frontend/app/lib/substrate-signing.ts` (new file)
  - Helper functions to:
    - Build messages for signing
    - Request signatures from Polkadot extension
    - Format signatures for contract calls

### 4.6 PVM Dashboard Enhancements

**What we're changing:**

The `/pvm` page currently just shows precompile status. We need to make it interactive.

**Files affected:**
- `frontend/app/pvm/page.tsx`
  - Add "Test Sr25519" button - sign and verify a message
  - Add "Test Blake2b" button - hash some data
  - Add "Test XCM" button - show XCM message encoding
  - Make it a showcase of PVM capabilities

### 4.7 Demo Mode

**What we're adding:**

A guided demo mode that walks judges through PVM features.

**Files affected:**
- `frontend/app/demo/page.tsx` (new file)
  - Step-by-step demo flow
  - Highlights Polkadot-specific features
  - Auto-fills example data
  - Links to relevant contract code

---

## Phase 5: Backend Improvements

> **Objective:** Transform backend from XCM simulator to XCM monitor

### 5.1 Current Backend Role

```
CURRENT:
1. Listen for XcmDispatched events
2. Wait a few seconds (simulate XCM travel time)
3. Call confirmDispatch() (simulate success)

PROBLEM: This is fake. There's no real XCM happening.
```

### 5.2 Target Backend Role

```
TARGET OPTION A (if XCM precompile works):
1. Listen for XcmDispatched events
2. Monitor destination parachain via @polkadot/api
3. Wait for real XCM confirmation
4. Call confirmDispatch() with proof

TARGET OPTION B (if XCM precompile doesn't work):
1. Keep event-based approach BUT
2. Add Blake2b hash verification
3. Clearly document this is a testnet limitation
4. Show that the code IS ready for real XCM
```

### 5.3 Polkadot API Integration

**What we're adding:**

Connection to Polkadot relay chain and parachains using @polkadot/api.

**Files affected:**
- `backend/package.json` - Add @polkadot/api dependency

- `backend/src/polkadotClient.js` (new file)
  - Connect to relay chain
  - Connect to destination parachains
  - Subscribe to XCM events
  - Query cross-chain message status

### 5.4 XCM Event Monitoring

**What we're changing:**

Replace simulation with real monitoring.

**Files affected:**
- `backend/src/dispatchMonitor.js`
  - Remove simulation delay
  - Add real XCM event subscription
  - Verify XCM message hashes match
  - Only confirm when real confirmation seen

### 5.5 Blake2b Hash Verification

**What we're adding:**

Server-side Blake2b hash verification to prove message authenticity.

**Files affected:**
- `backend/src/xcmVerifier.js` (new file)
  - Compute Blake2b hashes
  - Compare with on-chain hashes
  - Generate verification proofs

### 5.6 Health Endpoint Improvements

**What we're changing:**

Better health reporting for demo purposes.

**Files affected:**
- `backend/src/healthMonitor.js`
  - Add precompile status to health check
  - Add XCM connectivity status
  - Add @polkadot/api connection status

---

## Phase 6: Testing & Documentation

> **Objective:** Prove everything works and explain it clearly

### 6.1 Contract Tests

**What we're changing:**

Current tests mock PVM behavior. We need tests that:
1. Skip gracefully if precompile not available (local)
2. Run real tests on testnet fork

**Files affected:**
- `contracts/test/CryptoRegistry.t.sol`
  - Add testnet fork tests
  - Add real sr25519 signature verification test
  - Add real Blake2b test

- `contracts/test/XcmRouter.t.sol`
  - Add XCM precompile tests
  - Add message hash verification tests

- `contracts/test/integration/` (new folder)
  - End-to-end tests on testnet fork
  - Test full user flows

### 6.2 Test Vectors

**What we're adding:**

Pre-computed test vectors for:
- Sr25519 signatures (from known Polkadot test accounts)
- Ed25519 signatures
- Blake2b hashes
- XCM message encodings

**Files affected:**
- `contracts/test/fixtures/` (new folder)
  - `sr25519_vectors.json`
  - `ed25519_vectors.json`
  - `blake2b_vectors.json`
  - `xcm_vectors.json`

### 6.3 README Updates

**What we're changing:**

The README needs to clearly explain Track 2 features.

**Files affected:**
- `README.md` (project root, new file)
  - Clear "Track 2 PVM Features" section
  - Architecture diagrams
  - Setup instructions
  - Demo instructions

- `contracts/README.md`
  - Contract-specific documentation
  - Precompile addresses
  - Function descriptions

### 6.4 Pitch Documentation

**What we're adding:**

Hackathon submission materials.

**Files affected:**
- `docs/PITCH.md` (new file)
  - 2-page pitch document
  - Problem statement
  - Solution overview
  - PVM integration highlights
  - Future roadmap

- `docs/ARCHITECTURE.md` (new file)
  - Technical architecture
  - Diagrams
  - Data flow explanations

### 6.5 Demo Video Script

**What we're adding:**

A script for recording the demo video.

**Files affected:**
- `docs/DEMO_SCRIPT.md` (new file)
  - Step-by-step demo flow
  - Talking points for each feature
  - Commands to run
  - What to show on screen

---

## Risk Mitigation

### Risk 1: Precompiles Not Available

**Mitigation:**
- Phase 0 checks availability first
- Code includes testnet fallback mode
- Documentation clearly states "production-ready when precompiles deploy"

### Risk 2: XCM Precompile Complex or Different

**Mitigation:**
- Research XCM precompile interface thoroughly before coding
- Start with simple reserve transfers
- Have event-based fallback ready

### Risk 3: Frontend Wallet Integration Issues

**Mitigation:**
- Test with multiple wallets (Polkadot.js, Talisman, SubWallet)
- Keep MetaMask path working
- Provide clear user instructions

### Risk 4: Time Constraints

**Mitigation:**
- Phases are prioritized
- Phase 1 (Sr25519) alone is enough for Track 2 validity
- Each phase is independently valuable

### Risk 5: Breaking Existing Features

**Mitigation:**
- All changes are additive (new functions, not replacing old ones)
- Existing tests must pass
- Keep "legacy mode" for backwards compatibility

---

## File Change Summary

### New Files to Create

| File | Phase | Purpose |
|------|-------|---------|
| `test-precompiles.js` | 0 | Diagnostic tool |
| `contracts/src/interfaces/IAssetsPrecompile.sol` | 3 | Native assets interface |
| `frontend/app/components/polkadot-connect.tsx` | 4 | Polkadot wallet UI |
| `frontend/app/lib/substrate-signing.ts` | 4 | Signing helpers |
| `frontend/app/demo/page.tsx` | 4 | Demo walkthrough |
| `backend/src/polkadotClient.js` | 5 | Polkadot API client |
| `backend/src/xcmVerifier.js` | 5 | XCM verification |
| `contracts/test/fixtures/*.json` | 6 | Test vectors |
| `docs/PITCH.md` | 6 | Hackathon pitch |
| `docs/ARCHITECTURE.md` | 6 | Technical docs |
| `docs/DEMO_SCRIPT.md` | 6 | Demo script |
| `README.md` | 6 | Project overview |

### Existing Files to Modify

| File | Phase | Changes |
|------|-------|---------|
| `contracts/src/CryptoRegistry.sol` | 1 | Add strict mode, remove fallbacks |
| `contracts/src/libraries/PvmVerifier.sol` | 1 | Better error handling |
| `contracts/src/OmniShieldEscrow.sol` | 1, 3 | Substrate auth, native assets |
| `contracts/src/StealthPayment.sol` | 1, 3 | Require precompiles, native assets |
| `contracts/src/XcmRouter.sol` | 2 | Real XCM dispatch |
| `contracts/src/libraries/XcmBuilder.sol` | 2 | Better XCM encoding |
| `contracts/src/YieldRouter.sol` | 3 | Native asset support |
| `frontend/package.json` | 4 | Add Polkadot dependencies |
| `frontend/app/components/wallet-provider.tsx` | 4 | Dual wallet support |
| `frontend/app/escrow/page.tsx` | 4 | Substrate signing UI |
| `frontend/app/pvm/page.tsx` | 4 | Interactive PVM demo |
| `backend/package.json` | 5 | Add @polkadot/api |
| `backend/src/dispatchMonitor.js` | 5 | Real XCM monitoring |
| `backend/src/healthMonitor.js` | 5 | Better status reporting |
| `contracts/test/*.t.sol` | 6 | Real precompile tests |

---

## Success Criteria

### Minimum Viable Track 2 (must have all):

- [ ] At least ONE precompile-dependent feature that reverts on non-Polkadot chains
- [ ] Sr25519 signature verification working OR real XCM dispatch working
- [ ] Demo video showing Polkadot-exclusive feature
- [ ] Code comments explaining PVM integration

### Strong Track 2 Submission (aim for these):

- [ ] Sr25519 AND Ed25519 verification working
- [ ] Real XCM precompile dispatch
- [ ] Native Asset Hub assets support (USDT/USDC)
- [ ] Polkadot.js wallet integration in frontend
- [ ] Blake2b hash verification matching substrate
- [ ] Comprehensive test suite with real precompile tests
- [ ] Professional pitch documentation

### Winning Track 2 Submission (stretch goals):

- [ ] All above plus...
- [ ] Multi-validator sr25519 signature aggregation
- [ ] Cross-parachain yield routing with real XCM
- [ ] Stealth payments with Pedersen commitments
- [ ] Live demo on mainnet/kusama
- [ ] Gas optimization for precompile calls
- [ ] Security audit considerations documented

---

## Implementation Order

```
Week 1 (Days 1-3):
├── Phase 0: Run precompile check
├── Phase 1: CryptoRegistry strict mode
└── Phase 1: Substrate auth in Escrow

Week 1 (Days 4-5):
├── Phase 2: XCM Router improvements
└── Phase 3: Native asset interface (if precompile available)

Week 2 (Days 6-7):
├── Phase 4: Frontend Polkadot wallet
├── Phase 5: Backend monitoring
└── Phase 6: Testing & docs

Final Day:
├── Demo video recording
├── Final testing
└── Submission
```

---

## Questions to Resolve Before Coding

1. **Which testnet RPC should we use?** (Paseo? Westend? Polkadot Hub testnet?)
2. **Are sr25519/ed25519 precompiles deployed on the target testnet?**
3. **What is the exact interface of the XCM precompile (0x0816)?**
4. **What Asset IDs are available on Asset Hub testnet?**
5. **Do we have test DOT/tokens for testnet deployment?**

---

## Next Steps

1. **Run Phase 0** - Execute `test-precompiles.js` on testnet
2. **Share results** - Tell me which precompiles are available
3. **Start Phase 1** - I'll provide exact code for the available features
4. **Iterate** - We'll adjust based on what works

---

*This roadmap is a living document. Update it as we discover what works on the testnet.*

**Document Version:** 1.0
**Last Updated:** March 2026
**Author:** Development Team
