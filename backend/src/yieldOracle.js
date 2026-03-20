/**
 * @title Omni-Shield XCM Relayer — Yield Oracle
 * @description Periodically updates yield rates on the YieldRouter contract.
 *
 * In production: fetches real APY data from parachain DeFi protocols
 * On testnet: simulates dynamic APY changes for demo purposes
 */

const { config } = require("./config");
const { logger } = require("./logger");

// Simulated APY data per parachain (basis points)
const PARACHAIN_YIELDS = {
  2030: { name: "Bifrost vDOT", baseApy: 1200, variance: 200 },
  2034: { name: "HydraDX Omnipool", baseApy: 850, variance: 150 },
  2000: { name: "Acala LDOT", baseApy: 950, variance: 180 },
};

class YieldOracle {
  /**
   * @param {import('ethers').Contract} yieldRouter
   * @param {import('ethers').Provider} provider
   */
  constructor(yieldRouter, provider) {
    this.yieldRouter = yieldRouter;
    this.provider = provider;
    this.running = false;

    // Update interval: every 30 seconds on testnet
    this.updateIntervalMs = 30_000;
  }

  /**
   * Start the yield oracle update loop
   */
  async start() {
    this.running = true;
    logger.info("YieldOracle started");

    while (this.running) {
      try {
        await this._updateYields();
      } catch (err) {
        logger.error(`YieldOracle update error: ${err.message}`);
      }

      await this._sleep(this.updateIntervalMs);
    }
  }

  /**
   * Stop the oracle
   */
  stop() {
    this.running = false;
    logger.info("YieldOracle stopping...");
  }

  /**
   * Fetch latest yields and update on-chain
   */
  async _updateYields() {
    // Get source count from contract
    const sourceCount = await this.yieldRouter.getYieldSourceCount();

    for (let i = 0n; i < sourceCount; i++) {
      try {
        const source = await this.yieldRouter.getYieldSource(i);
        if (!source.isActive) continue;

        const paraId = Number(source.paraId);
        const yieldData = PARACHAIN_YIELDS[paraId];
        if (!yieldData) continue;

        // Simulate APY fluctuation
        const newApy = this._simulateApy(yieldData);

        // Only update if APY changed significantly (> 10 bps)
        const currentApy = Number(source.currentApyBps);
        if (Math.abs(newApy - currentApy) < 10) continue;

        logger.info(
          `Updating ${yieldData.name} APY: ${currentApy} → ${newApy} bps`
        );

        const tx = await this._sendUpdateWithRetry(i, newApy);
        await tx.wait(1);

        logger.info(`${yieldData.name} APY updated to ${newApy} bps`);
      } catch (err) {
        logger.warn(`Failed to update source ${i}: ${err.message}`);
      }
    }
  }

  /**
   * Simulate APY fluctuation for testnet
   * @param {{ baseApy: number, variance: number }} yieldData
   * @returns {number} New APY in basis points
   */
  _simulateApy(yieldData) {
    const delta = Math.floor(Math.random() * yieldData.variance * 2) - yieldData.variance;
    const newApy = yieldData.baseApy + delta;
    return Math.max(50, Math.min(5000, newApy)); // Clamp to 0.5%–50%
  }

  /**
   * Send APY update with retry logic for mempool replacement/priority conflicts.
   * @param {bigint} sourceIndex
   * @param {number} newApy
   */
  async _sendUpdateWithRetry(sourceIndex, newApy) {
    for (let attempt = 1; attempt <= config.maxTxRetries; attempt++) {
      try {
        const overrides = await this._buildTxOverrides(attempt);
        return await this.yieldRouter.updateYieldRate(sourceIndex, newApy, overrides);
      } catch (err) {
        const message = String(err && err.message ? err.message : err);
        const retryable = this._isRetryableTxError(message);
        if (!retryable || attempt === config.maxTxRetries) {
          throw err;
        }

        logger.warn(
          `Retrying APY update for source ${sourceIndex} after tx pricing/nonce conflict (attempt ${attempt}/${config.maxTxRetries})`
        );
        await this._sleep(1200 * attempt);
      }
    }

    throw new Error("APY update retries exhausted");
  }

  /**
   * Build transaction overrides with pending nonce and progressively bumped fees.
   * @param {number} attempt
   */
  async _buildTxOverrides(attempt) {
    const signer = this.yieldRouter.runner;
    const nonce = await signer.getNonce("pending");
    const feeData = await this.provider.getFeeData();

    const basePriority = feeData.maxPriorityFeePerGas || feeData.gasPrice || 1_000_000_000n;
    const baseMaxFee = feeData.maxFeePerGas || (basePriority * 2n);

    const baseMultiplier = Number.isFinite(config.gasPriceMultiplier)
      ? config.gasPriceMultiplier
      : 1.2;
    const bumpFactor = baseMultiplier + (attempt - 1) * 0.15;

    return {
      gasLimit: 300_000n,
      nonce,
      maxPriorityFeePerGas: this._applyMultiplier(basePriority, bumpFactor),
      maxFeePerGas: this._applyMultiplier(baseMaxFee, bumpFactor),
    };
  }

  /**
   * @param {bigint} value
   * @param {number} factor
   */
  _applyMultiplier(value, factor) {
    const bps = Math.max(100, Math.floor(factor * 100));
    return (value * BigInt(bps)) / 100n;
  }

  /**
   * @param {string} message
   */
  _isRetryableTxError(message) {
    const m = message.toLowerCase();
    return (
      m.includes("priority is too low") ||
      m.includes("replacement transaction underpriced") ||
      m.includes("nonce too low") ||
      m.includes("already known")
    );
  }

  /**
   * @param {number} ms
   */
  _sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}

module.exports = { YieldOracle };
