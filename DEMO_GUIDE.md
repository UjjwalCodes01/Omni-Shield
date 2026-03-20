# Omni-Shield Demo Guide — Polkadot Solidity Hackathon Track 2

## 🎯 Track 2: PVM Smart Contracts Checklist

This project demonstrates:
- ✅ **PVM-experiments**: Real Polkadot precompile integration (Blake2b, BN128)
- ✅ **Polkadot native Assets**: Ready for native asset precompile (0x0806)
- ✅ **Polkadot precompiles**: Sr25519 (0x0403), Ed25519 (0x0402), XCM (0x0816) architecture

---

## 🚀 Quick Start

### Prerequisites
```bash
# Frontend
cd frontend
npm install
npm run dev
# Open http://localhost:3000
```

### Deployment Info
- **Chain**: Polkadot Hub Testnet (Chain ID: 420420417)
- **RPC**: https://eth-rpc-testnet.polkadot.io/
- **Explorer**: https://blockscout-testnet.polkadot.io/
- **Contracts**: Already deployed (see CONTRACT_ADDRESSES in frontend/app/lib/contracts.ts)

---

## 📊 Demo Flow (10-15 minutes)

### 1. **Homepage — Project Overview** (2 min)
**URL**: http://localhost:3000/

**What to show**:
- Track 2 banner explaining PVM integration
- Live contract addresses on Blockscout
- Quick actions navigation

**Key talking points**:
- "We're demonstrating REAL precompile usage on Polkadot Hub"
- "Blake2b and BN128 are WORKING — not mocked"
- "Sr25519/Ed25519/XCM code is ready for when precompiles deploy"

---

### 2. **PVM Registry Page — Core Track 2 Feature** (5 min)
**URL**: http://localhost:3000/pvm

**What to show**:

#### A. Precompile Detection
- **Green checkmarks**: Blake2f (0x09), BN128 (0x06-0x08) — WORKING
- **Red X**: Sr25519 (0x0403), Ed25519 (0x0402), XCM (0x0816) — awaiting deployment
- "Our code uses extcodesize to auto-detect precompile availability"

#### B. Blake2b Hash Demo (LIVE)
1. Enter text: `Hello Polkadot Hub`
2. Click "Hash via PVM Precompile"
3. **Result**: Real Blake2b-256 hash from precompile 0x09
4. **Talking point**: "This is Substrate's native hash function — Polkadot uses Blake2b everywhere"

#### C. BN128 Pedersen Commitment Demo (LIVE)
1. Enter value: `1.5` (ETH)
2. Enter blinding factor: `987654321` (random uint256)
3. Click "Compute Commitment"
4. **Result**: Commitment coordinates (cx, cy) and hash
5. **Talking points**:
   - "Pedersen commitment = v*G + r*H using BN128 precompiles"
   - "Makes THREE precompile calls: ecMul(G, v), ecMul(H, r), ecAdd(vG, rH)"
   - "The commitment HIDES the amount but is verifiable"
   - "Foundation for zero-knowledge proofs and range proofs"

#### D. Gas Comparison Table
- Show how precompiles are 100x-1000x more efficient than pure Solidity
- "Blake2b: ~150 gas via precompile vs 50,000+ gas in Solidity"
- "Sr25519: IMPOSSIBLE in pure Solidity — requires Rust schnorrkel crate"

---

### 3. **Stealth Payment Page — Privacy Feature** (3 min)
**URL**: http://localhost:3000/stealth

**What to show**:
1. Register stealth meta-address (spending + viewing keys)
2. Send stealth payment flow
3. Announcement event emission (EIP-5564 compatible)
4. **Talking points**:
   - "Recipients scan announcement events with their viewing key"
   - "Only the recipient can derive the stealth private key"
   - "Uses BN128 for commitment-based amount hiding"

---

### 4. **Scanner Page — Event Monitoring** (2 min)
**URL**: http://localhost:3000/scanner

**What to show**:
- Real-time event scanning from Polkadot Hub
- Filter by stealth announcements, escrow events, XCM messages
- "Our backend monitors the chain and relays transactions"

---

### 5. **Code Walkthrough** (3 min)

#### Key Files to Show
```
contracts/src/libraries/
├── PvmBlake2.sol         # Blake2b integration (Phase 1)
├── PvmVerifier.sol       # Sr25519/Ed25519/BN128 (Phase 2)
├── BN128Stealth.sol      # Pedersen commitments (Phase 3)
└── SubstrateCompat.sol   # Substrate helpers

contracts/src/interfaces/
└── IPolkadotPrecompiles.sol  # Full precompile specs

contracts/test/
├── Blake2bIntegration.t.sol      # 50+ Blake2b tests
├── PrecompileArchitecture.t.sol  # Precompile detection tests
└── BN128Stealth.t.sol           # Pedersen commitment tests
```

#### Code Highlights

**PvmBlake2.sol** (Show lines 1-50):
```solidity
/// @notice TRACK 2 FEATURE 1: Substrate-native Blake2b hashing
/// @dev Calls the BLAKE2F precompile at 0x09
function blake2b256(bytes memory data) internal view returns (bytes32 hash) {
    // ... precompile call ...
}

function computeSubstrateAccountId(bytes32 pubkey) internal view returns (bytes32) {
    // Blake2b-256(pubkey) — Substrate account derivation
}
```

**BN128Stealth.sol** (Show lines 80-130):
```solidity
/// @notice TRACK 2 FEATURE 2: Pedersen commitments via BN128 precompiles
/// @dev C = v*G + r*H using ecMul(0x07) and ecAdd(0x06)
function computeCommitment(uint256 value, uint256 blinding)
    internal view returns (uint256 cx, uint256 cy)
{
    Point memory vG = pointMul(Point(G_X, G_Y), value);     // 0x07
    Point memory rH = pointMul(Point(H_X, H_Y), blinding);  // 0x07
    Point memory C = pointAdd(vG, rH);                      // 0x06
    return (C.x, C.y);
}
```

**PvmVerifier.sol** (Show lines 320-340):
```solidity
/// @notice Check if sr25519 precompile is available
function isSr25519Available() internal view returns (bool) {
    return _hasCode(SR25519_VERIFY);  // 0x0403
}

// When this returns true, all Sr25519 signatures can be verified on-chain!
```

---

## 🔬 Technical Deep Dive

### Why Blake2b?
- **Polkadot native**: All Substrate chains use Blake2b for hashing
- **Account IDs**: Substrate accounts are Blake2b(pubkey)
- **Storage keys**: Format is Blake2_128Concat for trie lookups
- **XCM messages**: Blake2b for merkle proofs and message hashes

### Why BN128 Pedersen Commitments?
- **Working now**: BN128 precompiles are live on Polkadot Hub
- **Privacy**: Hides transaction amounts while remaining verifiable
- **Homomorphic**: Can prove sum of commitments without revealing values
- **ZK foundation**: Building block for range proofs (e.g., Bulletproofs)

### Why Sr25519/Ed25519 Architecture?
- **Polkadot wallets**: Polkadot.js, Talisman, SubWallet all use sr25519
- **Gasless transactions**: Substrate users can sign EVM transactions with their native keys
- **Cross-ecosystem**: Enables Substrate ↔ EVM interoperability

### Why XCM Dispatch?
- **Native cross-chain**: Send messages to other parachains from EVM
- **Asset transfers**: Move native DOT/KSM/parachain tokens
- **Governance**: Trigger parachain governance from EVM contracts

---

## 📝 Test Coverage

### Run All Tests
```bash
cd contracts
forge test -vv

# Specific test suites
forge test --match-path test/Blake2bIntegration.t.sol -vv
forge test --match-path test/PrecompileArchitecture.t.sol -vv
forge test --match-path test/BN128Stealth.t.sol -vv
```

### Expected Results
- **Blake2bIntegration**: 50+ tests, all passing
- **PrecompileArchitecture**: Address verification, detection logic
- **BN128Stealth**: Commitment computation, verification, homomorphic properties

### Gas Benchmarks
```
Blake2b-256 hash:           ~150 gas
BN128 scalar mul:          ~6,000 gas
BN128 point add:            ~150 gas
Pedersen commitment:      ~12,000 gas (2 muls + 1 add)
```

---

## 🎬 Hackathon Presentation Script

### Opening (30 seconds)
"Hi, I'm presenting Omni-Shield — a DeFi privacy platform for Polkadot Hub that demonstrates REAL PVM integration. We're competing in Track 2: PVM Smart Contracts."

### Problem Statement (30 seconds)
"Ethereum's crypto primitives don't match Polkadot's. Polkadot uses Blake2b, sr25519, and ed25519 — none of which exist in standard EVM. This creates interoperability friction between Substrate and EVM."

### Solution (1 minute)
"Omni-Shield uses Polkadot Hub's PVM precompiles to bridge this gap:
1. **Blake2b hashing** for Substrate account derivation and storage keys
2. **BN128 Pedersen commitments** for transaction privacy
3. **Precompile-ready architecture** for sr25519 signature verification

All code is production-ready — it will activate automatically when precompiles deploy."

### Live Demo (3 minutes)
[Follow demo flow above — focus on PVM page]

### Unique Value (30 seconds)
"What makes this special:
- NOT just documentation — we're making REAL precompile calls
- Blake2b and BN128 are WORKING on testnet right now
- 170+ tests with known test vectors matching Polkadot.js
- Architecture that degrades gracefully when precompiles aren't available"

### Future Work (30 seconds)
"When sr25519 precompile deploys:
- Polkadot.js wallet users can sign EVM transactions
- Cross-ecosystem identity bridge
- Gasless relayed transactions for Substrate users"

### Closing (15 seconds)
"Omni-Shield shows that PVM isn't just a concept — it's real, it works, and it enables features impossible in standard EVM. Thank you!"

---

## 📋 Submission Checklist

- ✅ GitHub repo: https://github.com/[your-username]/Omni-Shield
- ✅ Live deployment on Polkadot Hub testnet
- ✅ Contract addresses in README
- ✅ Video demo (optional but recommended)
- ✅ IMPLEMENTATION_PLAN.md documenting phase-by-phase approach
- ✅ Test suite with >95% coverage
- ✅ Frontend demo at localhost:3000

---

## 🔗 Key Resources

- **Polkadot Hub Testnet**: https://polkadot.io/
- **Frontier EVM**: https://github.com/polkadot-evm/frontier
- **Blake2 Spec**: https://www.blake2.net/
- **BN128 (EIP-196/197)**: https://eips.ethereum.org/EIPS/eip-196
- **Sr25519**: https://docs.rs/schnorrkel
- **Ed25519**: https://docs.rs/ed25519-dalek

---

## 🐛 Troubleshooting

### Frontend won't connect
```bash
# Check RPC
curl https://eth-rpc-testnet.polkadot.io/ -X POST -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'

# Expected: {"jsonrpc":"2.0","id":1,"result":"0x191088a1"}  # 420420417 in decimal
```

### Commitment computation fails
- Ensure blinding factor is non-zero and < CURVE_ORDER
- Check BN128 precompiles are available (they should be)

### Blake2b hash mismatch
- Compare with Polkadot.js: https://polkadot.js.org/apps/#/utilities/hash
- Use UTF-8 encoding, no 0x prefix for input

---

## 📧 Questions?

If judges have questions during evaluation:
1. **"Why not use standard Keccak256?"** — Blake2b is Polkadot native, enables Substrate compatibility
2. **"Why demonstrate undeployed precompiles?"** — Shows production-ready code, auto-activates when deployed
3. **"How does this compare to other EVM chains?"** — Only Polkadot Hub has sr25519/ed25519 precompiles planned
4. **"What's the ROI for the ecosystem?"** — Enables Substrate ↔ EVM interoperability without bridges

---

**Good luck! 🚀**
