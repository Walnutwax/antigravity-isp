/**
 * antigravity-codex-theme · Managed CDP Utilities (core/shared.mjs)
 */
import fs from 'node:fs';
import http from 'node:http';

export function isAllowedOrigin(urlStr) {
  if (!urlStr || typeof urlStr !== 'string') return false;
  try {
    const url = new URL(urlStr);
    if (url.protocol === 'vscode-file:') return true;
    if (url.protocol === 'plugin:') return url.hostname.startsWith('swarm--');
    return (
      (url.protocol === 'http:' || url.protocol === 'https:') &&
      (url.hostname === '127.0.0.1' || url.hostname === 'localhost')
    );
  } catch {
    return false;
  }
}

export function readDebuggerEndpoint(portFile) {
  try {
    const raw = fs.readFileSync(portFile, 'utf8');
    const lines = raw.trimEnd().split(/\r?\n/);
    if (lines.length !== 2) return null;
    const [portLine, browserPath] = lines;
    const port = Number(portLine);
    const browserPathPattern = /^\/devtools\/browser\/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
    if (!Number.isInteger(port) || port < 1 || port > 65535 || String(port) !== portLine ||
        !browserPathPattern.test(browserPath)) {
      return null;
    }
    return { port, browserPath };
  } catch {
    return null;
  }
}

export function isAllowedDebuggerSocket(wsUrl, port) {
  const origin = `ws://127.0.0.1:${port}`;
  return (
    typeof wsUrl === 'string' &&
    wsUrl.startsWith(origin + '/') &&
    /^\/devtools\/page\/[\w-]+$/.test(wsUrl.slice(origin.length))
  );
}

export async function fetchTargets({ port, browserPath }) {
  const version = await fetchJson(port, '/json/version');
  if (version?.webSocketDebuggerUrl !== `ws://127.0.0.1:${port}${browserPath}`) return [];
  const targets = await fetchJson(port, '/json/list');
  return Array.isArray(targets) ? targets : [];
}

function fetchJson(port, path) {
  return new Promise((resolve) => {
    const req = http.get({ host: '127.0.0.1', port, path, timeout: 450 }, (res) => {
      if (res.statusCode !== 200) {
        res.destroy();
        resolve(null);
        return;
      }
      let data = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => {
        data += chunk;
        if (data.length > 2 * 1024 * 1024) {
          req.destroy();
          resolve(null);
        }
      });
      res.on('end', () => {
        try {
          resolve(JSON.parse(data));
        } catch {
          resolve(null);
        }
      });
      res.on('error', () => resolve(null));
    });
    req.on('error', () => resolve(null));
    req.on('timeout', () => {
      req.destroy();
      resolve(null);
    });
  });
}
