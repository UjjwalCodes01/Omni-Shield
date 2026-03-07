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
    const sourceCount = await this.yieldRouter.sourceCount();

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

        const tx = await this.yieldRouter.updateYieldRate(i, newApy, true, {
          gasLimit: 300_000n,
        });
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
   * @param {number} ms
   */
  _sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}

module.exports = { YieldOracle };
