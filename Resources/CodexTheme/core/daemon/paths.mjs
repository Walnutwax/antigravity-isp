/**
 * core/daemon/paths.mjs — Managed Stable Channel and Bundle Builder
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { parseArgs } from 'node:util';
import { fileURLToPath } from 'node:url';

const CORE_DIR = fileURLToPath(new URL('../', import.meta.url));
const BASE_VERSION = '1.3.1';
const STYLE_FILES = ['00-base.css', '10-light-codex.css', '20-dark-codex.css', '30-telemetry.css'];
const RUNTIME_FILES = [
  '00-head.js',
  '20-theme-sync.js',
  '30-antigravity-probe.js',
  '40-status-machine.js',
  '50-telemetry-ui.js',
  '60-i18n-engine.js',
  '90-tail.js'
];

export function parseDaemonCliArgs(argv = process.argv.slice(2)) {
  try {
    const { values } = parseArgs({
      args: argv,
      options: {
        channel: { type: 'string' },
        'port-file': { type: 'string' },
        once: { type: 'boolean', default: false }
      }
    });
    const portFile = values['port-file'];
    if (values.channel === 'stable' && portFile && path.isAbsolute(portFile)) {
      return { portFile, runOnce: values.once };
    }
  } catch {}
  return null;
}

function readCoreFile(...parts) {
  return fs.readFileSync(path.join(CORE_DIR, ...parts), 'utf8');
}

export function createBundleController({ portFile }) {
  let state;

  function rebuildBundleIfNeeded() {
    if (state) return false;

    const presetConfig = JSON.parse(readCoreFile('defaults.json'));
    const preset = presetConfig.preset === 'codex-dark' ? 'codex-dark' : 'codex-pure-white';
    const telemetryLayout = presetConfig.telemetryLayout === 'detailed' ? 'detailed' : 'compact';
    const telemetryCacheMode = presetConfig.telemetryCacheMode === 'step' ? 'step' : 'session';
    const modules = { theme: true, i18n: true, metrics: true };
    const endpoint = {
      channel: 'stable',
      portFile,
      lsLogFile: path.join(os.homedir(), 'Library', 'Logs', 'Antigravity', 'language_server.log'),
      conversationsDir: path.join(os.homedir(), '.gemini', 'antigravity', 'conversations')
    };

    const runtimeTemplate = RUNTIME_FILES.map((filename) => readCoreFile('runtime', filename)).join('\n');
    const bootPayload = {
      platform: process.platform,
      enabled: true,
      preset,
      telemetryLayout,
      telemetryCacheMode,
      cssText: STYLE_FILES.map((filename) => readCoreFile('styles', filename)).join('\n\n'),
      i18nDict: JSON.parse(readCoreFile('i18n.json')),
      modules
    };
    const hash = crypto
      .createHash('sha256')
      .update(runtimeTemplate)
      .update(JSON.stringify(bootPayload))
      .digest('hex')
      .slice(0, 8);
    const cachedPatchVersion = `${BASE_VERSION}-stable-${hash}`;
    const cachedInjectScript = runtimeTemplate.replace(
      '})(__AG_BOOT_PAYLOAD__);',
      () => `})(${JSON.stringify({ ...bootPayload, version: cachedPatchVersion })});`
    );
    state = {
      activeConfig: { enabled: true, telemetryLayout, telemetryCacheMode, modules, endpoint },
      cachedInjectScript,
      cachedPatchVersion
    };
    return true;
  }

  return { rebuildBundleIfNeeded, getState: () => state };
}
