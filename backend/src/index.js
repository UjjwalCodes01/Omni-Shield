/**
 * @title Omni-Shield XCM Relayer
 * @version 1.0.0
 * @description Off-chain relayer service for the Omni-Shield protocol.
 *
 * Responsibilities:
 *   1. Monitor XcmDispatched events from XcmRouter
 *   2. Confirm cross-chain delivery (or mark failed/timed-out)
 *   3. Handle withdrawal returns from parachains
 *   4. Update yield rates on YieldRouter (oracle role)
 *   5. Health monitoring and alerting
 *
 * Usage:
 *   cp .env.example .env
 *   # Fill in contract addresses and relayer key
 *   node src/index.js
 *
 * Architecture:
 *   ┌────────────────────────────────┐
 *   │        XCM Relayer             │
 *   │                                │
 *   │  ┌──────────────────────────┐  │
 *   │  │    DispatchMonitor       │  │  ← Watches XcmDispatched events
 *   │  │    (event listener)      │  │  ← Confirms / fails / timeouts
 *   │  └──────────────────────────┘  │
 *   │                                │
 *   │  ┌──────────────────────────┐  │
 *   │  │    YieldOracle           │  │  ← Updates APY rates on-chain
 *   │  │    (rate updater)        │  │  ← Simulated on testnet
 *   │  └──────────────────────────┘  │
 *   │                                │
 *   │  ┌──────────────────────────┐  │
 *   │  │    HealthMonitor         │  │  ← Chain connectivity checks
 *   │  │    (watchdog)            │  │  ← Balance & auth status
 *   │  └──────────────────────────┘  │
 *   └────────────────────────────────┘
 *              │         │
 *      ┌───────┘         └───────┐
 *      ▼                         ▼
 *  XcmRouter                YieldRouter
 *  (on-chain)               (on-chain)
 */

const { config, validateConfig } = require("./config");
const { logger } = require("./logger");
const { initContracts } = require("./contracts");
const { DispatchMonitor } = require("./dispatchMonitor");
const { YieldOracle } = require("./yieldOracle");
const { HealthMonitor } = require("./healthMonitor");
const fs = require("fs");
const http = require("http");

// Ensure logs directory exists
if (!fs.existsSync("logs")) {
  fs.mkdirSync("logs", { recursive: true });
}

async function main() {
  logger.info("========================================");
  logger.info("  Omni-Shield XCM Relayer v1.0.0");
  logger.info("========================================");

  // Validate configuration
  const { valid, errors } = validateConfig();
  if (!valid) {
    for (const err of errors) {
      logger.error(`Config error: ${err}`);
    }
    process.exit(1);
  }

  // Initialize contract connections
  const { provider, signer, xcmRouter, yieldRouter } = initContracts();

  // Verify relayer authorization
  const isRelayer = await xcmRouter.isAuthorizedRelayer(signer.address);
  if (!isRelayer) {
    logger.error(
      `Relayer ${signer.address} is NOT authorized on XcmRouter at ${config.xcmRouterAddress}`
    );
    logger.error("Run: cast send <XcmRouter> 'addRelayer(address)' <relayerAddr>");
    process.exit(1);
  }

  logger.info(`Relayer authorized: ${signer.address}`);
  logger.info(`XcmRouter:    ${config.xcmRouterAddress}`);
  logger.info(`YieldRouter:  ${config.yieldRouterAddress}`);
  logger.info(`Chain ID:     ${config.chainId}`);
  logger.info(`Poll interval: ${config.pollIntervalMs}ms`);

  // Start services
  const dispatchMonitor = new DispatchMonitor(xcmRouter, yieldRouter, provider);
  const yieldOracle = new YieldOracle(yieldRouter, provider);
  const healthMonitor = new HealthMonitor(xcmRouter, yieldRouter, provider, signer);

  // Optional HTTP server for platforms (e.g., Render Web Service) that require an open port.
  let statusServer = null;
  if (process.env.PORT) {
    statusServer = http.createServer((req, res) => {
      const now = new Date().toISOString();

      if (req.url === "/" || req.url === "/health") {
        const body = JSON.stringify({
          service: "omni-shield-relayer",
          status: "ok",
          time: now,
          chainId: config.chainId,
          xcmRouter: config.xcmRouterAddress,
          yieldRouter: config.yieldRouterAddress,
        });
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(body);
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Not found" }));
    });

    await new Promise((resolve) => {
      statusServer.listen(Number(process.env.PORT), "0.0.0.0", resolve);
    });

    logger.info(`HTTP status server listening on port ${process.env.PORT}`);
  }

  // Graceful shutdown
  const shutdown = () => {
    logger.info("Shutdown signal received...");
    dispatchMonitor.stop();
    yieldOracle.stop();
    healthMonitor.stop();
    if (statusServer) {
      statusServer.close();
    }
    setTimeout(() => process.exit(0), 2000);
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);

  // Launch all services concurrently
  await Promise.all([
    dispatchMonitor.start(),
    yieldOracle.start(),
    healthMonitor.start(),
  ]);
}

main().catch((err) => {
  logger.error(`Fatal error: ${err.message}`, { stack: err.stack });
  process.exit(1);
});
