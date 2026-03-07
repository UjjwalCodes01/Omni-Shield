/**
 * @title Omni-Shield XCM Relayer — Health Monitor
 * @description Monitors relayer health, contract state, and chain connectivity
 */

const { logger } = require("./logger");

class HealthMonitor {
  /**
   * @param {import('ethers').Contract} xcmRouter
   * @param {import('ethers').Contract} yieldRouter
   * @param {import('ethers').Provider} provider
   * @param {import('ethers').Wallet} signer
   */
  constructor(xcmRouter, yieldRouter, provider, signer) {
    this.xcmRouter = xcmRouter;
    this.yieldRouter = yieldRouter;
    this.provider = provider;
    this.signer = signer;
    this.running = false;

    // Check every 60 seconds
    this.checkIntervalMs = 60_000;
  }

  async start() {
    this.running = true;
    logger.info("HealthMonitor started");

    while (this.running) {
      try {
        await this._healthCheck();
      } catch (err) {
        logger.error(`Health check failed: ${err.message}`);
      }

      await this._sleep(this.checkIntervalMs);
    }
  }

  stop() {
    this.running = false;
  }

  async _healthCheck() {
    // 1. Check chain connectivity
    const blockNumber = await this.provider.getBlockNumber();

    // 2. Check relayer balance
    const balance = await this.provider.getBalance(this.signer.address);
    const balanceEth = Number(balance) / 1e18;

    if (balanceEth < 0.01) {
      logger.warn(`Low relayer balance: ${balanceEth.toFixed(6)} DOT`);
    }

    // 3. Check contract state
    const pending = await this.xcmRouter.pendingDispatches();
    const inTransit = await this.xcmRouter.amountInTransit();
    const isRelayer = await this.xcmRouter.isAuthorizedRelayer(
      this.signer.address
    );
    const paused = await this.xcmRouter.paused();

    logger.info("Health check", {
      block: blockNumber,
      relayerBalance: `${balanceEth.toFixed(6)} DOT`,
      pendingDispatches: pending.toString(),
      amountInTransit: `${Number(inTransit) / 1e18} DOT`,
      isAuthorizedRelayer: isRelayer,
      contractPaused: paused,
    });

    if (!isRelayer) {
      logger.error("Relayer is NOT authorized on XcmRouter!");
    }
    if (paused) {
      logger.warn("XcmRouter is PAUSED — dispatches blocked");
    }
  }

  _sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}

module.exports = { HealthMonitor };
