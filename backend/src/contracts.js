/**
 * @title Omni-Shield XCM Relayer — Contract Bindings
 * @description Ethers.js v6 contract instances for all protocol contracts
 */

const { ethers } = require("ethers");
const { config } = require("./config");
const { logger } = require("./logger");
const path = require("path");
const fs = require("fs");

/**
 * Load ABI from the abi/ directory
 * @param {string} name Contract name (e.g., "XcmRouter")
 * @returns {any[]} ABI array
 */
function loadAbi(name) {
  const abiPath = path.join(__dirname, "..", "abi", `${name}.json`);
  return JSON.parse(fs.readFileSync(abiPath, "utf-8"));
}

/**
 * Initialize provider, signer, and contract instances
 * @returns {{ provider, signer, xcmRouter, yieldRouter }}
 */
function initContracts() {
  const provider = new ethers.JsonRpcProvider(config.rpcUrl, config.chainId);
  const signer = new ethers.Wallet(config.relayerPrivateKey, provider);

  logger.info(`Relayer address: ${signer.address}`);

  const xcmRouter = new ethers.Contract(
    config.xcmRouterAddress,
    loadAbi("XcmRouter"),
    signer
  );

  const yieldRouter = new ethers.Contract(
    config.yieldRouterAddress,
    loadAbi("YieldRouter"),
    signer
  );

  // Optional contracts
  let escrow = null;
  let hub = null;
  if (config.escrowAddress) {
    escrow = new ethers.Contract(
      config.escrowAddress,
      loadAbi("OmniShieldEscrow"),
      signer
    );
  }
  if (config.hubAddress) {
    hub = new ethers.Contract(
      config.hubAddress,
      loadAbi("OmniShieldHub"),
      signer
    );
  }

  return { provider, signer, xcmRouter, yieldRouter, escrow, hub };
}

module.exports = { initContracts, loadAbi };
