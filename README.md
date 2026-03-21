# Omni-Shield — Polkadot Solidity Hackathon (Track 2)

[![Polkadot Hub](https://img.shields.io/badge/Polkadot-Hub%20Testnet-E6007A?style=flat&logo=polkadot)](https://polkadot.io/)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-363636?style=flat&logo=solidity)](https://soliditylang.org/)
[![Tests](https://img.shields.io/badge/Tests-170%2B-success?style=flat)]()
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat)](LICENSE)

> **Privacy-preserving DeFi protocol demonstrating real PVM integration on Polkadot Hub**

**Track 2 Submission**: PVM Smart Contracts — Blake2b hashing, BN128 Pedersen commitments, and precompile-ready architecture for Sr25519/Ed25519/XCM.

---

## ✅ Submission Deliverables Checklist

This section maps directly to the judging requirements.

| Requirement | Status | Evidence |
|-------------|--------|----------|
| Polkadot on-chain identity | ⚠️ Team action required | Add your verified identity profile link from Polka-Assembly/OpenGov |
| Quality documentation | ✅ Included | This README contains project scope, architecture, setup, deployment, and roadmap |
| UI/UX experience | ✅ Included | Live dashboard with multi-page flows (`/`, `/pvm`, `/stealth`, `/yield`, `/xcm`, `/escrow`) |
| Demonstration (hosted or local) | ✅ Included | Hosted frontend + hosted backend + local install guide below |
| Vision and commitment | ✅ Included | Future roadmap section with activation plan as precompiles roll out |
| Track relevance | ✅ Included | Track 2-focused implementation: Blake2b + BN128 + precompile-ready architecture |


## 🎯 Track 2: PVM Smart Contracts

| Requirement | Status | Implementation |
|-------------|--------|----------------|
| **PVM-experiments** (call Rust/C++ from Solidity) | ✅ **Working** | Blake2b (0x09), BN128 (0x06-0x08) precompiles |
| **Polkadot native Assets** | ✅ **Ready** | Interface defined (0x0806), auto-activates |
| **Polkadot precompiles** | ✅ **Architecture Ready** | Sr25519 (0x0403), Ed25519 (0x0402), XCM (0x0816) |

---

## 🚀 Quick Start

### Live Deployment (Polkadot Hub Testnet)

Network:

- Chain ID: 420420417
- RPC: https://eth-rpc-testnet.polkadot.io/
- Explorer: https://blockscout-testnet.polkadot.io/

Contracts:

- **CryptoRegistry**: 0x237259A349F258eD5d561F90dcb701f4371169B3 — PVM precompile registry
- **StealthPayment**: 0x98DB1edC0ED10888d559C641F709A364818B0167 — EIP-5564 stealth addresses
- **StealthVault**: 0x5290EC1961854B8a45346f74BeF775E51d4Ba076 — Commitment-based privacy vault
- **OmniShieldEscrow**: 0xFa10b866e5B4a3BDD2d0a978FCB5cAbb334372BE — Multi-party escrow
- **YieldRouter**: 0xa4B00C51eD83c7a9E1F646E9C0329F4E61f651F1 — Cross-chain yield aggregation
- **XcmRouter**: 0x2BA3337232F5b1eA4b14f3ca0121C3272c25Bb4E — XCM message dispatcher
- **OmniShieldHub**: 0xCe7917f133B5f31807cC839DCC44f836D8ca7142 — Central coordinator

### Frontend Demo

```bash
cd frontend
npm install
npm run dev
# Open http://localhost:3000
```

**Key Pages**:
- `/` — Dashboard with Track 2 banner
- `/pvm` — **PVM Registry & Live Demos** (main feature)
- `/stealth` — Private payment flows
- `/scanner` — Event monitoring

Hosted frontend: https://omni-shield-zeta.vercel.app/

Hosted backend health endpoint: https://omni-shield.onrender.com/health

### Run Tests

```bash
cd contracts
forge install
forge test -vv

# Track 2 test suites
forge test --match-path test/Blake2bIntegration.t.sol -vv       # 50+ Blake2b tests
forge test --match-path test/PrecompileArchitecture.t.sol -vv  # Precompile detection
forge test --match-path test/BN128Stealth.t.sol -vv           # Pedersen commitments
```

---

## 🔬 Technical Innovation

### 1. **Blake2b Integration** ✅ WORKING

**Why**: Polkadot uses Blake2b for account IDs, storage keys, and merkle trees. Standard EVM only has Keccak256.

**Implementation**: `contracts/src/libraries/PvmBlake2.sol`

```solidity
/// @notice Compute Substrate AccountId from public key
function computeSubstrateAccountId(bytes32 pubkey)
    internal view returns (bytes32 accountId)
{
    return blake2b256(abi.encodePacked(pubkey));
}

/// @notice Blake2_128Concat storage key (Substrate format)
function blake2b128Concat(bytes memory key)
    internal view returns (bytes memory storageKey)
{
    bytes16 hash = blake2b128(key);
    return abi.encodePacked(hash, key);
}
```

**Live Demo**: Try `/pvm` page → Blake2b Hasher

---

### 2. **BN128 Pedersen Commitments** ✅ WORKING

**Why**: Transaction privacy through amount hiding. Foundation for zero-knowledge proofs.

**Implementation**: `contracts/src/libraries/BN128Stealth.sol`

```solidity
/// @notice Compute Pedersen commitment: C = v*G + r*H
/// @dev Uses BN128 precompiles (ecMul 0x07, ecAdd 0x06)
function computeCommitment(uint256 value, uint256 blindingFactor)
    internal view returns (uint256 cx, uint256 cy)
{
    Point memory vG = pointMul(Point(G_X, G_Y), value);
    Point memory rH = pointMul(Point(H_X, H_Y), blindingFactor);
    Point memory C = pointAdd(vG, rH);
    return (C.x, C.y);
}
```

**Properties**:
- Perfectly hiding (reveals nothing about value)
- Computationally binding (cannot find different opening)
- Homomorphic (C1 + C2 commits to v1 + v2)

**Gas**: ~12,000 gas (vs 100,000+ in pure Solidity)

**Live Demo**: Try `/pvm` page → BN128 Pedersen Commitment

---

### 3. **Precompile-Ready Architecture** ✅ CODE READY

**Why**: When sr25519/ed25519/XCM precompiles deploy, features activate automatically.

**Implementation**: `contracts/src/libraries/PvmVerifier.sol`, `contracts/src/interfaces/IPolkadotPrecompiles.sol`

**Detection Matrix**:

| Precompile | Address | Status | Notes |
|------------|---------|--------|-------|
| Blake2f | 0x09 | ✅ Working | Substrate hashing |
| BN128 Add/Mul/Pairing | 0x06-0x08 | ✅ Working | Privacy commitments |
| Sr25519 Verify | 0x0403 | 🔄 Code Ready | Polkadot.js signatures |
| Ed25519 Verify | 0x0402 | 🔄 Code Ready | Validator signatures |
| XCM Dispatch | 0x0816 | 🔄 Code Ready | Cross-chain messaging |

**Graceful Degradation**: Functions return `false` when precompiles unavailable, no reverts.

---

## 🏗️ Architecture

### Smart Contracts

```
contracts/src/
├── CryptoRegistry.sol          # Central precompile registry (Track 2 core)
├── StealthPayment.sol          # EIP-5564 stealth addresses
├── OmniShieldEscrow.sol        # Multi-party escrow
├── YieldRouter.sol             # Cross-chain yield
├── XcmRouter.sol               # XCM dispatcher
├── libraries/
│   ├── PvmBlake2.sol           # Blake2b integration (Phase 1)
│   ├── PvmVerifier.sol         # Sr25519/Ed25519/BN128 (Phase 2)
│   ├── BN128Stealth.sol        # Pedersen commitments (Phase 3)
│   └── SubstrateCompat.sol     # Substrate helpers
└── interfaces/
    ├── IPolkadotPrecompiles.sol # Precompile specs
    └── ...
```

### Test Coverage

**Total Tests**: 170+

| Suite | Tests | Focus |
|-------|-------|-------|
| `Blake2bIntegration.t.sol` | 50+ | Known test vectors |
| `PrecompileArchitecture.t.sol` | 25+ | Detection logic |
| `BN128Stealth.t.sol` | 30+ | Commitment math |
| `CryptoRegistry.t.sol` | 20+ | Registry functions |
| `StealthPayment.t.sol` | 40+ | Privacy flows |

---

## 🎥 Demo Script (Quick)

**Quick demo path for judges**:
1. Homepage (`/`) — Track 2 banner and overview
2. **PVM Registry** (`/pvm`) — Live Blake2b hashing + Pedersen commitment demo
3. Stealth Payments (`/stealth`) — Private payment flow
4. Code walkthrough — Show precompile integration

### Demo Assets

- Demo video URL: `<ADD_DEMO_VIDEO_LINK>`

---

## 🔑 Key Differentiators

✅ **Real Precompile Integration** — ACTUAL precompile calls, not mocks
✅ **Production-Ready** — 170+ tests, error handling, gas optimization
✅ **Substrate Compatible** — Blake2b accounts, storage keys, XCM hashing
✅ **Graceful Degradation** — Auto-detect and adapt to precompile availability

---

## 📚 Documentation Scope

This README is the canonical submission document and includes:

- Problem statement and track mapping
- Live deployment details
- Contract architecture and precompile integration
- Test coverage summary
- Judge demo path
- Local installation and verification steps
- Future roadmap and commitment

## Local Setup Guide

### Prerequisites

- Node.js 20+
- npm
- Foundry (forge, cast)

### 1) Smart Contracts

```bash
cd contracts
forge install
forge build
forge test -vv
```

### 2) Frontend Dashboard

```bash
cd frontend
npm install
npm run dev
# Open http://localhost:3000
```

### 3) Backend Relayer (Optional)

```bash
cd backend
cp .env.example .env
# Fill .env with contract addresses and relayer key
npm install
npm run dev
```

---

## 🚀 Future Roadmap

### When Sr25519 Deploys (0x0403)
- Polkadot.js wallet signature verification
- Gasless transactions for Substrate users
- Cross-ecosystem identity bridge

### When XCM Deploys (0x0816)
- Native DOT/KSM transfers from EVM
- Cross-parachain messaging
- Governance triggers from smart contracts

### Privacy Enhancements
- Range proofs using BN128 pairing (0x08)
- zk-SNARKs for private transactions
- Confidential asset registry

---

## 🙏 Acknowledgments

- **Polkadot Team**: For PVM architecture and Frontier EVM
- **Parity Technologies**: For Substrate & Polkadot.js
- **Moonbeam Team**: For precompile design patterns
- **EIP-5564 Authors**: For stealth address specification

---

## 📜 License

MIT License. See LICENSE.
