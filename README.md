# Omni-Shield

Omni-Shield is a Polkadot-native security and payments protocol that combines:

- Stealth payments and scan-based recipient discovery
- Production escrow flows with disputes and conditional release
- Cross-chain yield routing over XCM
- Relayer-based dispatch confirmation and on-chain yield updates
- Dashboard UX for operations, treasury, payroll, and monitoring

This repository is prepared for hackathon submission and testing.

## Track Relevance

Primary relevance:

- Polkadot Hub EVM smart contracts
- Cross-chain and XCM routing
- Polkadot-native precompile integration (runtime-dependent)

Core contracts are in the contracts module and backend relayer logic is in backend.

## Repository Structure

```
omni-shield/
  contracts/   # Foundry smart contracts and tests
  backend/     # Node relayer, monitors, yield oracle
  frontend/    # Next.js dashboard and user flows
```

## Architecture

High-level flow:

1. User deposits to YieldRouter or creates Escrow from frontend.
2. YieldRouter requests dispatch through XcmRouter.
3. Backend relayer monitors dispatch state and confirms/fails routes.
4. YieldOracle updates source APYs on-chain for routing decisions.
5. HealthMonitor reports balance, pending dispatches, and paused status.
6. CryptoRegistry provides cryptographic precompile status and wrappers.

Key modules:

- contracts/src/OmniShieldEscrow.sol
- contracts/src/YieldRouter.sol
- contracts/src/XcmRouter.sol
- contracts/src/StealthPayment.sol
- contracts/src/StealthVault.sol
- contracts/src/CryptoRegistry.sol
- contracts/src/OmniShieldHub.sol

## Deployed Contracts (Polkadot Hub TestNet)

Network:

- Chain ID: 420420417
- RPC: https://eth-rpc-testnet.polkadot.io/
- Explorer: https://blockscout-testnet.polkadot.io/

Contracts:

- OmniShieldEscrow: 0xFa10b866e5B4a3BDD2d0a978FCB5cAbb334372BE
- StealthPayment: 0x98DB1edC0ED10888d559C641F709A364818B0167
- StealthVault: 0x5290EC1961854B8a45346f74BeF775E51d4Ba076
- YieldRouter: 0xa4B00C51eD83c7a9E1F646E9C0329F4E61f651F1
- XcmRouter: 0x2BA3337232F5b1eA4b14f3ca0121C3272c25Bb4E
- CryptoRegistry: 0x237259A349F258eD5d561F90dcb701f4371169B3
- OmniShieldHub: 0xCe7917f133B5f31807cC839DCC44f836D8ca7142

## Local Setup Guide

### Prerequisites

- Node.js 20+
- npm
- Foundry (forge, cast)

### 1) Smart Contracts

```bash
cd contracts
forge build
forge test
```

### 2) Backend Relayer

```bash
cd backend
cp .env.example .env
```

Fill backend/.env with:

- RELAYER_PRIVATE_KEY
- XCM_ROUTER_ADDRESS
- YIELD_ROUTER_ADDRESS
- ESCROW_ADDRESS
- STEALTH_PAYMENT_ADDRESS
- HUB_ADDRESS

Run relayer:

```bash
npm install
npm run dev
```

### 3) Frontend Dashboard

```bash
cd frontend
npm install
npm run dev
```

Production build check:

```bash
npm run build
```

## Testing

Contracts are tested in Foundry under contracts/test.

Current suite covers:

- Escrow lifecycle and dispute flows
- Stealth payment and stealth vault flows
- Yield route state transitions
- XCM routing dispatch and timeout behavior
- CryptoRegistry wrappers and availability reporting

Run all tests:

```bash
cd contracts
forge test -vv
```

## Demo

Submission demo checklist:

- Hosted frontend URL: ADD_URL_HERE
- Demo video: ADD_VIDEO_URL_HERE
- Screenshots: ADD_SCREENSHOT_LINKS_HERE

Suggested demo path:

1. Connect wallet on dashboard.
2. Create escrow and show release/refund behavior.
3. Deposit to YieldRouter and show route creation.
4. Show relayer logs for dispatch and health checks.
5. Show scanner and payroll pages as advanced UX modules.

## Security Notes

- Never commit private keys or populated .env files.
- Rotate relayer key immediately if ever exposed.
- Precompile availability is runtime-dependent and can differ by network.
- Use backend/.env.example as the template, not backend/.env.

## Known Limitations

- Some precompiles can be unavailable on current testnet runtime.
- Cross-chain confirmation is relayer-assisted in this version.
- Backend currently has no dedicated unit test suite.

## Roadmap

Phase 1: Hackathon MVP

- Complete full dashboard and end-to-end relayer operations
- Maintain contract verification and reproducible setup

Phase 2: Mainnet Hardening

- Add backend tests and stronger alerting
- Expand monitoring and signer policy controls

Phase 3: Ecosystem Integrations

- Extend parachain strategy sources
- Improve operator tooling and reporting

## Compliance Checklist

- Open-source repository with public source
- Root MIT license added
- Clear local setup and test commands
- Track relevance documented
- Demo section prepared for final links

Manual items to complete before final submission:

- Team identity verification on official Polkadot Discord
- Polkadot on-chain identity setup for winner eligibility
- Final demo video and public hosted link

## License

MIT License. See LICENSE.
