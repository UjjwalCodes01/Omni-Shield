# Omni-Shield Frontend

Next.js dashboard for Omni-Shield protocol operations and user flows.

## Routes

- /
- /yield
- /stealth
- /escrow
- /xcm
- /pvm
- /scanner
- /payroll
- /disputes
- /settings

## Development

```bash
npm install
npm run dev
```

Open http://localhost:3000.

Environment variable (optional, defaults to Render backend URL):

- `NEXT_PUBLIC_BACKEND_URL=https://omni-shield.onrender.com`

## Production Build

```bash
npm run build
npm run start
```

## Chain Context

Frontend is configured for Polkadot Hub TestNet (chain ID 420420417) and uses deployed protocol addresses from app/lib/stealth.ts.

## Notes

- Wallet connection and tx execution require a compatible EVM wallet.
- Some precompile status indicators depend on runtime support at the active network.
- The dashboard "Backend Relayer" card checks `${NEXT_PUBLIC_BACKEND_URL}/health` to verify frontend-backend connectivity.
- For full project setup and submission details, see the root README.
