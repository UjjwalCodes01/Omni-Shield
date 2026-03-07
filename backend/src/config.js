/**
 * @title Omni-Shield XCM Relayer — Configuration
 * @description Loads and validates environment configuration
 */

require("dotenv").config();

const config = {
  // EVM / Polkadot Hub
  rpcUrl: process.env.RPC_URL || "https://eth-rpc-testnet.polkadot.io/",
  chainId: parseInt(process.env.CHAIN_ID || "420420417"),
  relayerPrivateKey: process.env.RELAYER_PRIVATE_KEY || "",

  // Contract addresses
  xcmRouterAddress: process.env.XCM_ROUTER_ADDRESS || "",
  yieldRouterAddress: process.env.YIELD_ROUTER_ADDRESS || "",
  escrowAddress: process.env.ESCROW_ADDRESS || "",
  stealthPaymentAddress: process.env.STEALTH_PAYMENT_ADDRESS || "",
  hubAddress: process.env.HUB_ADDRESS || "",

  // Relayer settings
  pollIntervalMs: parseInt(process.env.POLL_INTERVAL_MS || "6000"),
  maxTxRetries: parseInt(process.env.MAX_TX_RETRIES || "3"),
  gasPriceMultiplier: parseFloat(process.env.GAS_PRICE_MULTIPLIER || "1.2"),
  confirmationBlocks: parseInt(process.env.CONFIRMATION_BLOCKS || "2"),
  logLevel: process.env.LOG_LEVEL || "info",
};

/**
 * Validate required configuration
 * @returns {{ valid: boolean, errors: string[] }}
 */
function validateConfig() {
  const errors = [];

  if (!config.relayerPrivateKey) {
    errors.push("RELAYER_PRIVATE_KEY is required");
  }
  if (!config.xcmRouterAddress) {
    errors.push("XCM_ROUTER_ADDRESS is required");
  }
  if (!config.yieldRouterAddress) {
    errors.push("YIELD_ROUTER_ADDRESS is required");
  }

  return { valid: errors.length === 0, errors };
}

module.exports = { config, validateConfig };
