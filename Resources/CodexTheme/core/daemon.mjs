#!/usr/bin/env node
/**
 * antigravity-codex-theme · CDP Theme, Localization & Live Telemetry Daemon (core/daemon.mjs)
 */
import { DatabaseSync } from 'node:sqlite';
import { parseDaemonCliArgs, createBundleController } from './daemon/paths.mjs';
import { createCdpManager } from './daemon/cdp-bridge.mjs';
import { createMetricsReader } from './daemon/sqlite-metrics.mjs';

const cliOpts = parseDaemonCliArgs();
if (!cliOpts) {
  console.error('Usage: node daemon.mjs --channel stable --port-file <absolute path> [--once]');
  process.exit(2);
}

const bundleCtrl = createBundleController(cliOpts);
const metricsReader = createMetricsReader({
  getDatabaseSync: () => DatabaseSync,
  getConfig: () => bundleCtrl.getState().activeConfig
});
const cdpManager = createCdpManager({ bundleCtrl, metricsReader, runOnce: cliOpts.runOnce });
bundleCtrl.rebuildBundleIfNeeded();

try {
  await cdpManager.sync();
  if (cliOpts.runOnce) {
    cdpManager.closeAll();
  } else {
    setInterval(() => {
      cdpManager.sync().catch(() => console.error('[Codex Theme] CDP synchronization failed'));
    }, 2500);
  }
} catch {
  cdpManager.closeAll();
  console.error('[Codex Theme] Initial CDP synchronization failed');
  process.exitCode = 1;
}
