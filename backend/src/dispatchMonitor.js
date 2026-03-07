/**
 * @title Omni-Shield XCM Relayer — Dispatch Monitor
 * @description Listens for XcmDispatched events from XcmRouter and confirms
 *              them after observing successful cross-chain execution.
 *
 * Architecture:
 *   - Polls for new XcmDispatched events
 *   - Simulates cross-chain delivery confirmation (on testnet, no real XCM)
 *   - Calls confirmDispatch() after a configurable delay
 *   - Handles failures by calling markDispatchFailed()
 *   - Monitors timeouts and auto-marks them
 *
 * In production with real XCM:
 *   - Would use @polkadot/api to monitor destination parachain
 *   - Confirm when funds arrive via xcm.Attempted event
 *   - On failure, detect xcm.Failed and report
 */

const { config } = require("./config");
const { logger } = require("./logger");

// XCM dispatch status tracking
const XCM_STATUS = {
  PENDING: 0,
  CONFIRMED: 1,
  FAILED: 2,
  TIMED_OUT: 3,
};

class DispatchMonitor {
  /**
   * @param {import('ethers').Contract} xcmRouter
   * @param {import('ethers').Contract} yieldRouter
   * @param {import('ethers').Provider} provider
   */
  constructor(xcmRouter, yieldRouter, provider) {
    this.xcmRouter = xcmRouter;
    this.yieldRouter = yieldRouter;
    this.provider = provider;
    this.lastProcessedBlock = 0;
    this.pendingDispatches = new Map(); // dispatchId => dispatch data
    this.running = false;

    // Testnet: simulate confirmation delay (2 polling cycles)
    this.confirmationDelay = config.pollIntervalMs * config.confirmationBlocks;
  }

  /**
   * Start monitoring for XCM dispatch events
   */
  async start() {
    this.running = true;
    this.lastProcessedBlock = await this.provider.getBlockNumber();
    logger.info(`DispatchMonitor started at block ${this.lastProcessedBlock}`);

    // Main polling loop
    while (this.running) {
      try {
        await this._pollEvents();
        await this._processConfirmations();
        await this._checkTimeouts();
      } catch (err) {
        logger.error(`DispatchMonitor poll error: ${err.message}`, {
          stack: err.stack,
        });
      }

      await this._sleep(config.pollIntervalMs);
    }
  }

  /**
   * Stop the monitor gracefully
   */
  stop() {
    this.running = false;
    logger.info("DispatchMonitor stopping...");
  }

  /**
   * Poll for new XcmDispatched events
   */
  async _pollEvents() {
    const currentBlock = await this.provider.getBlockNumber();
    if (currentBlock <= this.lastProcessedBlock) return;

    const fromBlock = this.lastProcessedBlock + 1;
    const toBlock = currentBlock;

    logger.debug(`Scanning blocks ${fromBlock}–${toBlock} for XcmDispatched`);

    // Query XcmDispatched events
    const filter = this.xcmRouter.filters.XcmDispatched();
    const events = await this.xcmRouter.queryFilter(filter, fromBlock, toBlock);

    for (const event of events) {
      const { dispatchId, routeId, paraId, amount, xcmMessageHash } =
        event.args;

      const id = dispatchId.toString();
      if (this.pendingDispatches.has(id)) continue;

      logger.info(
        `New XCM dispatch: id=${id}, route=${routeId}, paraId=${paraId}, amount=${amount}`,
        { txHash: event.transactionHash }
      );

      this.pendingDispatches.set(id, {
        dispatchId: dispatchId,
        routeId: routeId,
        paraId: Number(paraId),
        amount: amount,
        xcmMessageHash: xcmMessageHash,
        detectedAt: Date.now(),
        blockNumber: event.blockNumber,
        txHash: event.transactionHash,
        confirmAttempts: 0,
      });
    }

    // Also check for WithdrawalInitiated events on YieldRouter
    await this._pollWithdrawals(fromBlock, toBlock);

    this.lastProcessedBlock = toBlock;
  }

  /**
   * Poll for withdrawal events to initiate XCM returns
   */
  async _pollWithdrawals(fromBlock, toBlock) {
    try {
      const filter = this.yieldRouter.filters.WithdrawalInitiated();
      const events = await this.yieldRouter.queryFilter(
        filter,
        fromBlock,
        toBlock
      );

      for (const event of events) {
        const { routeId, user, amount } = event.args;
        logger.info(
          `Withdrawal initiated: route=${routeId}, user=${user}, amount=${amount}`
        );

        // Find the dispatch ID for this route
        const dispatchId = await this.xcmRouter.getDispatchForRoute(routeId);
        if (dispatchId > 0n) {
          await this._initiateReturn(dispatchId, routeId, amount);
        }
      }
    } catch (err) {
      logger.warn(`Failed to poll withdrawals: ${err.message}`);
    }
  }

  /**
   * Process pending dispatches — confirm after delay
   *
   * On testnet: We simulate XCM confirmation after a short delay.
   * On mainnet: This would check the destination parachain via @polkadot/api
   * for the xcm.Attempted event confirming fund delivery.
   */
  async _processConfirmations() {
    const now = Date.now();

    for (const [id, dispatch] of this.pendingDispatches) {
      // Check if enough time has passed to simulate XCM confirmation
      const elapsed = now - dispatch.detectedAt;
      if (elapsed < this.confirmationDelay) continue;

      // On testnet: auto-confirm (no real XCM to verify)
      // On mainnet: verify via destination parachain state query
      try {
        await this._confirmDispatch(id, dispatch);
        this.pendingDispatches.delete(id);
      } catch (err) {
        dispatch.confirmAttempts++;
        logger.error(
          `Failed to confirm dispatch ${id} (attempt ${dispatch.confirmAttempts}): ${err.message}`
        );

        if (dispatch.confirmAttempts >= config.maxTxRetries) {
          logger.error(`Max retries reached for dispatch ${id}, marking failed`);
          try {
            await this._markFailed(id, `Relayer confirmation failed: ${err.message}`);
          } catch (failErr) {
            logger.error(`Failed to mark dispatch ${id} as failed: ${failErr.message}`);
          }
          this.pendingDispatches.delete(id);
        }
      }
    }
  }

  /**
   * Confirm a dispatch on the XcmRouter contract
   */
  async _confirmDispatch(id, dispatch) {
    logger.info(`Confirming dispatch ${id} for parachain ${dispatch.paraId}`);

    const tx = await this.xcmRouter.confirmDispatch(dispatch.dispatchId, {
      gasLimit: 500_000n,
    });
    const receipt = await tx.wait(1);

    logger.info(`Dispatch ${id} confirmed`, {
      txHash: receipt.hash,
      gasUsed: receipt.gasUsed.toString(),
    });
  }

  /**
   * Mark a dispatch as failed
   */
  async _markFailed(id, reason) {
    logger.warn(`Marking dispatch ${id} as failed: ${reason}`);

    const dispatchId = BigInt(id);
    const tx = await this.xcmRouter.markDispatchFailed(dispatchId, reason, {
      gasLimit: 500_000n,
    });
    await tx.wait(1);

    logger.info(`Dispatch ${id} marked as failed`);
  }

  /**
   * Initiate a return XCM transfer for withdrawal
   */
  async _initiateReturn(dispatchId, routeId, amount) {
    logger.info(
      `Initiating return for dispatch ${dispatchId}, route ${routeId}`
    );

    try {
      // On testnet: simulate yield earned (0.1% for demo)
      const yieldEarned = amount / 1000n;

      const tx = await this.xcmRouter.initiateReturn(
        dispatchId,
        yieldEarned,
        { gasLimit: 500_000n }
      );
      await tx.wait(1);
      logger.info(`Return initiated for dispatch ${dispatchId}`);

      // Simulate return confirmation after a brief delay
      setTimeout(async () => {
        try {
          await this._confirmReturn(dispatchId, amount + yieldEarned);
        } catch (err) {
          logger.error(
            `Failed to confirm return for ${dispatchId}: ${err.message}`
          );
        }
      }, this.confirmationDelay);
    } catch (err) {
      logger.error(`Failed to initiate return: ${err.message}`);
    }
  }

  /**
   * Confirm that return funds have arrived and forward to YieldRouter
   */
  async _confirmReturn(dispatchId, totalAmount) {
    logger.info(`Confirming return for dispatch ${dispatchId}`);

    const tx = await this.xcmRouter.confirmReturn(dispatchId, {
      value: totalAmount,
      gasLimit: 500_000n,
    });
    await tx.wait(1);

    logger.info(`Return confirmed for dispatch ${dispatchId}`, {
      amount: totalAmount.toString(),
    });
  }

  /**
   * Check for timed-out dispatches and mark them
   */
  async _checkTimeouts() {
    try {
      const dispatchCount = await this.xcmRouter.getDispatchCount();

      for (let i = 1n; i <= dispatchCount; i++) {
        const timedOut = await this.xcmRouter.isTimedOut(i);
        if (timedOut) {
          logger.warn(`Dispatch ${i} has timed out, marking...`);
          try {
            const tx = await this.xcmRouter.markTimedOut(i, {
              gasLimit: 300_000n,
            });
            await tx.wait(1);
            logger.info(`Dispatch ${i} marked as timed out`);
          } catch (err) {
            // Already timed out by someone else, or not pending
            logger.debug(
              `Could not mark timeout for ${i}: ${err.message}`
            );
          }
        }
      }
    } catch (err) {
      logger.debug(`Timeout check error: ${err.message}`);
    }
  }

  /**
   * @param {number} ms
   */
  _sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}

module.exports = { DispatchMonitor };
