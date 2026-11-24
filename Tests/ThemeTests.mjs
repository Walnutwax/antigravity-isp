import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { Script, runInNewContext } from 'node:vm';
import { createBundleController } from '../Resources/CodexTheme/core/daemon/paths.mjs';
import { createMetricsReader } from '../Resources/CodexTheme/core/daemon/sqlite-metrics.mjs';
import {
  isAllowedDebuggerSocket,
  isAllowedOrigin,
  readDebuggerEndpoint
} from '../Resources/CodexTheme/core/shared.mjs';

const themeRoot = new URL('../Resources/CodexTheme/', import.meta.url);
const daemonPath = fileURLToPath(new URL('core/daemon.mjs', themeRoot));
const runFile = promisify(execFile);

function temporaryDirectory(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'antigravity-isp-theme-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

test('bundled renderer parses and leaves external documents untouched', () => {
  const bundle = createBundleController({ portFile: '/tmp/synthetic-DevToolsActivePort' });
  assert.equal(bundle.rebuildBundleIfNeeded(), true);
  const { cachedInjectScript, activeConfig } = bundle.getState();
  const renderer = new Script(cachedInjectScript);
  const window = { location: { protocol: 'https:', hostname: 'example.test' } };
  window.top = window;
  renderer.runInNewContext({ window });
  assert.equal(window.__ag_patch_version, undefined);
  assert.equal(activeConfig.telemetryLayout, 'detailed');
  assert.deepEqual(activeConfig.modules, { theme: true, i18n: true, metrics: true });
  assert.doesNotMatch(cachedInjectScript, /__AG_BOOT_PAYLOAD__|new Function\(/);
});

test('model effort aliases retain correct long-wait and model-switch status', () => {
  const probe = fs.readFileSync(new URL('core/runtime/30-antigravity-probe.js', themeRoot), 'utf8');
  const status = fs.readFileSync(new URL('core/runtime/40-status-machine.js', themeRoot), 'utf8');
  for (const script of [status, probe + '\n' + status]) {
    const compute = runInNewContext(script + '\ncomputeStatusSnapshot');
    const observation = { st: { pendingKind: 'llm', lastModelLabel: 'Gemini 4 Hydrogen (XHigh)' }, waitSec: 65 };
    const sameModel = compute({ ...observation, curModel: 'Gemini 4 Hydrogen (Extra High)' });
    assert.equal(sameModel.visualState, 'slow');
    assert.doesNotMatch(sameModel.noteHtml, /模型已切换/);
    assert.match(compute({ ...observation, curModel: 'Gemini 4 Hydrogen (High)' }).noteHtml, /模型已切换/);
  }
});

test('read-only telemetry counts completed and pruned checkpoints and retains TTFT', (t) => {
  const dir = temporaryDirectory(t);
  const id = '00000000-0000-0000-0000-000000000001';
  const db = new DatabaseSync(path.join(dir, `${id}.db`));
  try {
    db.exec(`
      CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, size INTEGER, data BLOB);
      CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, status INTEGER,
                          metadata BLOB, step_payload BLOB, error_details BLOB);
      INSERT INTO steps (idx, step_type, status) VALUES
        (0, 14, 3), (1, 23, 5), (2, 23, 3), (3, 15, 3), (4, 23, 2), (5, 23, 7), (6, 15, 5);
    `);
    // Chat protobuf with 20 input tokens, 8 output tokens, 1s TTFT and 2s streaming.
    const metadata = Buffer.from('0a0e2204101418085a020801620208021003', 'hex');
    db.prepare('INSERT INTO gen_metadata (idx, size, data) VALUES (?, ?, ?)').run(0, metadata.length, metadata);
  } finally {
    db.close();
  }

  const metrics = createMetricsReader({
    getDatabaseSync: () => DatabaseSync,
    getConfig: () => ({ telemetryLayout: 'detailed' })
  });
  const result = metrics.parseConversationMetrics(id, dir);
  assert.equal(result.hasData, true);
  assert.equal(result.stats.compactionCount, 2);
  assert.equal(result.stats.compactingNow, true);
  assert.equal(result.stats.ttft, 1);
  assert.equal(result.stats.tps, 4);
  assert.match(result.tooltipHtml, /已压缩 2 次/);
  assert.match(result.tooltipHtml, /TTFT 1\.00s/);
});

test('only the supplied app CDP listener can receive a target socket connection', { timeout: 15000 }, async (t) => {
  const portFile = path.join(temporaryDirectory(t), 'DevToolsActivePort');
  const browserPath = '/devtools/browser/00000000-0000-0000-0000-000000000001';
  const paths = [];
  const socketPaths = [];
  let advertiseExpectedBrowser = false;
  const server = http.createServer((req, res) => {
    paths.push(req.url);
    if (req.url === '/json/version') {
      const path = advertiseExpectedBrowser
        ? browserPath
        : '/devtools/browser/00000000-0000-0000-0000-000000000002';
      res.end(JSON.stringify({ webSocketDebuggerUrl: `ws://127.0.0.1:${port}${path}` }));
      return;
    }
    const targetOrigin = 'vscode-file://vscode-app/editor.html';
    res.end(JSON.stringify([
      {
        id: 'valid',
        type: 'page',
        url: targetOrigin,
        webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/valid`
      },
      {
        id: 'wrong-path',
        type: 'page',
        url: targetOrigin,
        webSocketDebuggerUrl: `ws://127.0.0.1:${port}/wrong-path`
      },
      {
        id: 'spoof-origin',
        type: 'page',
        url: 'http://127.0.0.1.example.test/editor.html',
        webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/spoof-origin`
      }
    ]));
  });
  server.on('upgrade', (req, socket) => {
    socketPaths.push(req.url);
    socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
  });
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const listening = once(server, 'listening');
  server.listen(0, '127.0.0.1');
  await listening;
  const { port } = server.address();

  const base = `ws://127.0.0.1:${port}`;
  assert.equal(isAllowedDebuggerSocket(`${base}/devtools/page/valid`, port), true);
  assert.equal(isAllowedDebuggerSocket(`${base}/devtools/page/valid?query`, port), false);
  assert.equal(isAllowedDebuggerSocket('ws://192.0.2.4:12345/devtools/page/valid', 12345), false);
  assert.equal(isAllowedDebuggerSocket('ws://127.0.0.1:12345/devtools/page/valid', 12346), false);
  assert.equal(isAllowedOrigin('https://localhost.example.test/editor.html'), false);
  assert.equal(isAllowedOrigin('http://127.0.0.1:8080/editor.html'), true);

  const run = (...args) => runFile(process.execPath, [daemonPath, ...args], { timeout: 6000 });
  const runOnce = () => run('--channel', 'stable', '--port-file', portFile, '--once');
  await assert.rejects(run('--channel', 'stable', '--once'), { code: 2 });
  await runOnce();
  assert.deepEqual(paths, []);
  for (const malformed of [`${port}\n`, `0${port}\n${browserPath}\n`, `${port}\n/devtools/browser/no-uuid\n`]) {
    fs.writeFileSync(portFile, malformed);
    assert.equal(readDebuggerEndpoint(portFile), null);
    await runOnce();
    assert.deepEqual(paths, []);
  }

  fs.writeFileSync(portFile, `${port}\n${browserPath}\n`);
  assert.deepEqual(readDebuggerEndpoint(portFile), { port, browserPath });
  await runOnce();
  assert.deepEqual(paths, ['/json/version']);
  assert.deepEqual(socketPaths, []);

  paths.length = 0;
  advertiseExpectedBrowser = true;
  await runOnce();
  assert.deepEqual(paths, ['/json/version', '/json/list']);
  assert.deepEqual(socketPaths, ['/devtools/page/valid']);
});
