# Omni-Shield Backend Relayer

Node.js relayer for Omni-Shield operational workflows:

- XCM dispatch monitoring
- Dispatch confirmation and failure handling
- Yield source APY updates (oracle loop)
- Health checks and operator logs

## Prerequisites

- Node.js 20+
- npm

## Setup

```bash
cp .env.example .env
npm install
```

Required .env values:

- RELAYER_PRIVATE_KEY
- XCM_ROUTER_ADDRESS
- YIELD_ROUTER_ADDRESS
- ESCROW_ADDRESS
- STEALTH_PAYMENT_ADDRESS
- HUB_ADDRESS

Default network values in .env.example target Polkadot Hub TestNet.

## Run

```bash
npm run dev
```

or

```bash
npm start
```

## Deploy On Render

Use a Background Worker (recommended for this relayer) with these settings:

- Root Directory: `backend`
- Build Command: `npm install`
- Start Command: `npm start`

Do not use `npm build` (invalid npm command). If you prefer a build step, use `npm run build` only when a `build` script exists.

Required Render environment variables:

- `RELAYER_PRIVATE_KEY` (real 0x-prefixed 32-byte private key, not placeholder text)
- `XCM_ROUTER_ADDRESS`
- `YIELD_ROUTER_ADDRESS`
- `ESCROW_ADDRESS`
- `STEALTH_PAYMENT_ADDRESS`
- `HUB_ADDRESS`

Optional (defaults exist):

- `RPC_URL`
- `CHAIN_ID`
- `POLL_INTERVAL_MS`
- `MAX_TX_RETRIES`
- `GAS_PRICE_MULTIPLIER`
- `CONFIRMATION_BLOCKS`
- `LOG_LEVEL`

This repository also includes a Render Blueprint at `render.yaml` to avoid manual misconfiguration.

## Runtime Modules

- src/index.js: service bootstrap and shutdown hooks
- src/contracts.js: ABI loading and contract instance wiring
- src/dispatchMonitor.js: dispatch event polling and confirmation flow
- src/yieldOracle.js: APY updates for registered sources
- src/healthMonitor.js: relayer status, balances, pending dispatches
- src/config.js: environment validation and defaults
- src/logger.js: structured logging

## Operational Notes

- Relayer must be authorized in the deployed XcmRouter and/or YieldRouter.
- Keep relayer key funded for gas and never commit populated .env files.
- If runtime precompile support changes, refresh on-chain precompile status accordingly.