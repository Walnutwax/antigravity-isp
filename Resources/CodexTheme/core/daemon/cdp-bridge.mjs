/**
 * core/daemon/cdp-bridge.mjs — CDP Target Discovery, Host Fingerprint Gate & Swarm Relay
 */
import {
  isAllowedOrigin,
  readDebuggerEndpoint,
  fetchTargets,
  isAllowedDebuggerSocket
} from '../shared.mjs';
import { getLsLogSig } from './ls-log.mjs';
import { getDbSignature } from './sqlite-metrics.mjs';

function getTargetOriginKey(urlStr) {
  try {
    const u = new URL(String(urlStr || ''));
    return `${u.protocol}//${u.host}`;
  } catch {
    return String(urlStr || '').slice(0, 64);
  }
}

export const SKIPPED_TARGET_BACKOFF_MS = Object.freeze([4000, 10000, 25000]);
export const SKIPPED_TARGET_MAX_RETRIES = SKIPPED_TARGET_BACKOFF_MS.length;

export function getNextSkippedTargetEntry(prevEntry, { origin, nowMs = Date.now(), timedOut = false } = {}) {
  const sameOrigin = Boolean(prevEntry && prevEntry.origin === origin);
  if (timedOut) {
    const prevTimeouts = sameOrigin ? Number(prevEntry.timeoutCount || 0) : 0;
    const delayMs = prevTimeouts < 3 ? 3000 : 12000;
    return {
      origin,
      atMs: nowMs,
      nextRetryAtMs: nowMs + delayMs,
      attempts: sameOrigin ? Number(prevEntry.attempts || 0) : 0,
      timeoutCount: prevTimeouts + 1,
      exhausted: false
    };
  }
  const attempts = (sameOrigin ? Number(prevEntry.attempts || 0) : 0) + 1;
  if (attempts > SKIPPED_TARGET_MAX_RETRIES) {
    return {
      origin,
      atMs: nowMs,
      nextRetryAtMs: Number.POSITIVE_INFINITY,
      attempts,
      timeoutCount: 0,
      exhausted: true
    };
  }
  return {
    origin,
    atMs: nowMs,
    nextRetryAtMs: nowMs + SKIPPED_TARGET_BACKOFF_MS[attempts - 1],
    attempts,
    timeoutCount: 0,
    exhausted: false
  };
}

export function isSkippedTargetCoolingDown(entry, currentOrigin, nowMs = Date.now()) {
  if (!entry || entry.origin !== currentOrigin) return false;
  if (entry.exhausted) return true;
  return nowMs < Number(entry.nextRetryAtMs || 0);
}

export function createCdpManager({ bundleCtrl, metricsReader, runOnce = false }) {
  const attachedTargets = new Map();
  const skippedNonHostTargets = new Map();
  const targetMetaMap = new Map();
  const targetThemeModes = new Map();
  let isSyncing = false;
  let syncTickCount = 0;
  let lastTargetDiscoveryMs = 0;
  let connectedDebuggerEndpoint = '';
  const TARGET_DISCOVERY_INTERVAL_MS = 12500;

  function resolveParentThemeMode(targetId, channel) {
    let curId = targetId;
    for (let depth = 0; depth < 6 && curId; depth += 1) {
      const meta = targetMetaMap.get(curId);
      const pid = meta?.parentId || null;
      if (pid && targetThemeModes.has(pid)) {
        return targetThemeModes.get(pid);
      }
      curId = pid;
    }
    for (const [id, mode] of targetThemeModes.entries()) {
      const meta = targetMetaMap.get(id);
      if (!channel || !meta?.channel || meta.channel === channel) {
        return mode;
      }
    }
    return '';
  }

  async function relayThemeModeToChildIframes(parentId, channel, mode) {
    if (mode !== 'dark' && mode !== 'light') return;
    for (const [id, entry] of attachedTargets.entries()) {
      if (!entry.isSwarmIframe || !entry.hostConfirmed) continue;
      if (channel && entry.endpoint?.channel && entry.endpoint.channel !== channel) continue;
      if (parentId && entry.parentId && entry.parentId !== parentId) {
        const resolved = resolveParentThemeMode(id, entry.endpoint?.channel);
        if (resolved && resolved !== mode) continue;
      }
      try {
        await entry.send('Runtime.evaluate', {
          expression: `window.__ag_host_theme_mode = ${JSON.stringify(mode)}; if (typeof window.__ag_set_host_theme_mode === 'function') window.__ag_set_host_theme_mode(${JSON.stringify(mode)});`,
          returnByValue: false
        });
        if (entry.updateNewDocScript) {
          await entry.updateNewDocScript();
        }
      } catch {}
    }
  }

  function attachTarget(target, endpoint) {
    const wsUrl = target.webSocketDebuggerUrl;
    if (!isAllowedDebuggerSocket(wsUrl, endpoint.port)) return Promise.resolve(false);
    const isSwarmIframe = target.type === 'iframe' && String(target.url || '').startsWith('plugin://swarm--');

    return new Promise((resolveAttach) => {
      let settled = false;
      const finishAttach = (ok) => {
        if (!settled) {
          settled = true;
          resolveAttach(ok);
        }
      };
      const attachTimeout = setTimeout(() => finishAttach(false), 3000);

      try {
        const ws = new WebSocket(wsUrl);
        let msgId = 1;
        let activeCascadeIds = [];
        const pushedSessions = new Map();
        let evalScriptId = null;
        let hostConfirmed = isSwarmIframe;
        let currentTargetUrl = target.url || '';
        const pendingCallbacks = new Map();

        const parseCascadeIdList = (raw) => {
          const out = [];
          const pushId = (val) => {
            const s = String(val || '').trim();
            if (/^[0-9a-f-]{36}$/i.test(s) && !out.includes(s)) out.push(s);
          };
          if (Array.isArray(raw)) {
            for (const item of raw) pushId(item);
            return out.slice(0, 6);
          }
          const str = String(raw || '').trim();
          if (!str) return out;
          if (str.startsWith('[')) {
            try {
              const parsed = JSON.parse(str);
              if (Array.isArray(parsed)) {
                for (const item of parsed) pushId(item);
                return out.slice(0, 6);
              }
            } catch {}
          }
          for (const part of str.split(/[,\s]+/)) pushId(part);
          return out.slice(0, 6);
        };

        const send = (method, params = {}) =>
          new Promise((resolve) => {
            if (ws.readyState !== WebSocket.OPEN) return resolve(null);
            const id = msgId++;
            const timer = setTimeout(() => {
              pendingCallbacks.delete(id);
              resolve(null);
            }, 2500);
            pendingCallbacks.set(id, (msg) => {
              clearTimeout(timer);
              resolve(msg);
            });
            ws.send(JSON.stringify({ id, method, params }));
          });

        const buildEffectiveScript = () => {
          const { cachedInjectScript } = bundleCtrl.getState();
          if (!isSwarmIframe) return cachedInjectScript;
          const inheritedMode = resolveParentThemeMode(target.id, endpoint.channel);
          const preamble = inheritedMode ? `window.__ag_host_theme_mode = ${JSON.stringify(inheritedMode)};\n` : '';
          return `${preamble}${cachedInjectScript}`;
        };

        const verifyHostTarget = async () => {
          if (isSwarmIframe) return { isHost: true, timedOut: false };
          const probe = await send('Runtime.evaluate', {
            expression: `(() => {
              const loc = window.location;
              const isHost = Boolean(
                (loc && loc.protocol === 'vscode-file:') ||
                (window.__APP_CONFIG__ && window.__APP_CONFIG__.productName === 'antigravity') ||
                (window.electronNative && (
                  typeof window.electronNative.setTitleBarOverlay === 'function' ||
                  typeof window.electronNative.getZoomLevel === 'function'
                )) ||
                (typeof document !== 'undefined' && document.querySelector &&
                  document.querySelector('link[href*="/jetbox.css"], body[data-agy-theme], body[data-newux-theme], [id="antigravity.agentSidePanelInputBox"]'))
              );
              return isHost;
            })()`,
            returnByValue: true
          });
          if (!probe) return { isHost: false, timedOut: true };
          return { isHost: probe?.result?.result?.value === true, timedOut: false };
        };

        const updateNewDocScript = async () => {
          if (!hostConfirmed) return;
          const { activeConfig } = bundleCtrl.getState();
          if (evalScriptId) {
            await send('Page.removeScriptToEvaluateOnNewDocument', { identifier: evalScriptId });
            evalScriptId = null;
          }
          if (activeConfig.enabled) {
            const addRes = await send('Page.addScriptToEvaluateOnNewDocument', { source: buildEffectiveScript() });
            if (addRes?.result?.identifier) {
              evalScriptId = addRes.result.identifier;
            }
          }
        };

        const inject = async () => {
          if (!hostConfirmed) return false;
          const { cachedPatchVersion } = bundleCtrl.getState();
          const res = await send('Runtime.evaluate', {
            expression: buildEffectiveScript(),
            returnByValue: true
          });
          if (!res?.result || res.result.exceptionDetails) {
            console.error('[Codex Theme] Renderer did not accept the theme bundle');
            return false;
          }
          console.log(
            `[Codex Theme] Injected (${cachedPatchVersion}) into ${isSwarmIframe ? 'swarm iframe' : 'Antigravity window'}`
          );
          return true;
        };

        const syncMetricsForSession = async (force = false) => {
          if (isSwarmIframe || !hostConfirmed) return;
          const { activeConfig } = bundleCtrl.getState();
          if (!activeConfig.modules.metrics) return;

          if (activeCascadeIds.length === 0 || force) {
            const evalRes = await send('Runtime.evaluate', {
              expression: `(function(){
                if (typeof window.__ag_get_watched_cascade_ids === 'function') {
                  const list = window.__ag_get_watched_cascade_ids();
                  if (Array.isArray(list)) return list;
                }
                const out = [];
                const add = (id) => {
                  const s = String(id || '').trim();
                  if (/^[0-9a-f-]{36}$/i.test(s) && !out.includes(s)) out.push(s);
                };
                if (window.__ag_watched_cascade_id) add(window.__ag_watched_cascade_id);
                const m = window.location.pathname.match(/\\/c\\/([0-9a-f-]{36})/i);
                if (m) {
                  add(m[1]);
                } else if (!document.querySelector('[data-testid="home-greeting"], [data-testid="home-splash-content"]')) {
                  const el = document.querySelector('[data-testid=conversation-row-sidebar][data-selected=true]');
                  if (el) add(el.getAttribute('data-cascade-id'));
                }
                document.querySelectorAll('[data-testid="side-question-tab-conversation"][data-cascade-id]').forEach((el) => {
                  if (!el.querySelector('[data-testid="side-question-tab-empty"]')) {
                    add(el.getAttribute('data-cascade-id'));
                  }
                });
                return out;
              })()`,
              returnByValue: true
            });
            const detected = parseCascadeIdList(evalRes?.result?.result?.value);
            activeCascadeIds = detected;
            for (const existingCid of [...pushedSessions.keys()]) {
              if (!activeCascadeIds.includes(existingCid)) {
                pushedSessions.delete(existingCid);
              }
            }
          }
          if (activeCascadeIds.length === 0) return;

          for (const cid of activeCascadeIds) {
            const prev = pushedSessions.get(cid) || { hash: '', pendingActive: false };
            const rawSig = getDbSignature(cid, endpoint.conversationsDir) || 'empty';
            const lsSig = prev.pendingActive ? getLsLogSig(endpoint.lsLogFile) : '';
            const sessionKey = `${cid}@${rawSig}|ly:${activeConfig.telemetryLayout}:${activeConfig.telemetryCacheMode}${lsSig ? `|ls:${lsSig}` : ''}`;
            if (!force && sessionKey === prev.hash) continue;

            const payload = metricsReader.parseConversationMetrics(cid, endpoint.conversationsDir, {
              lsLogFile: endpoint.lsLogFile,
              lsSig
            });
            if (!payload || payload.transientError) {
              if (force && payload?.cachedPayload) {
                await send('Runtime.evaluate', {
                  expression: `(window.__ag_last_daemon_hb = Date.now(), window.__ag_render_metrics && window.__ag_render_metrics(${JSON.stringify(payload.cachedPayload)}))`,
                  returnByValue: false
                });
              }
              continue;
            }

            const nextPendingActive = Boolean(
              payload.stats &&
                (payload.stats.generatingPending || payload.stats.compactingNow || payload.stats.pendingRetrying)
            );
            await send('Runtime.evaluate', {
              expression: `(window.__ag_last_daemon_hb = Date.now(), window.__ag_render_metrics && window.__ag_render_metrics(${JSON.stringify(payload)}))`,
              returnByValue: false
            });
            pushedSessions.set(cid, { hash: sessionKey, pendingActive: nextPendingActive });
          }
        };

        const checkAndInject = async () => {
          if (!hostConfirmed) return;
          try {
            const { activeConfig, cachedPatchVersion } = bundleCtrl.getState();
            const checkRes = await send('Runtime.evaluate', {
              expression:
                '((window.__ag_last_daemon_hb = Date.now()), window.__ag_refresh_wait_ui && window.__ag_refresh_wait_ui(), window.__ag_patch_version === ' +
                JSON.stringify(cachedPatchVersion) +
                ' && (' +
                JSON.stringify(!activeConfig.enabled) +
                ' || (window.__ag_body_ready === true && !!document.getElementById("ag-codex-theme"))))',
              returnByValue: true
            });
            if (checkRes?.result?.result?.value !== true) {
              await inject();
              await syncMetricsForSession(true);
            }
          } catch {}
        };

        let initialAttachDone = false;
        let navDebounceTimer = null;

        ws.addEventListener('open', async () => {
          await send('Page.enable');
          await send('Runtime.enable');

          const { isHost, timedOut } = await verifyHostTarget();
          if (!isHost) {
            const origin = getTargetOriginKey(currentTargetUrl);
            skippedNonHostTargets.set(
              target.id,
              getNextSkippedTargetEntry(skippedNonHostTargets.get(target.id), {
                origin,
                nowMs: Date.now(),
                timedOut
              })
            );
            try {
              ws.close();
            } catch {}
            clearTimeout(attachTimeout);
            finishAttach(false);
            return;
          }
          skippedNonHostTargets.delete(target.id);
          hostConfirmed = true;
          const entryRef = attachedTargets.get(target.id);
          if (entryRef) entryRef.hostConfirmed = true;

          if (!isSwarmIframe) {
            await send('Runtime.addBinding', { name: '__agRequestMetrics' });
            await send('Runtime.addBinding', { name: '__agSyncHostThemeMode' });
          }
          await updateNewDocScript();
          const ok = await inject();
          if (!isSwarmIframe) {
            const modeRes = await send('Runtime.evaluate', {
              expression: `document.documentElement ? (document.documentElement.getAttribute('data-ag-theme-mode') || '') : ''`,
              returnByValue: true
            });
            const resolvedMode = String(modeRes?.result?.result?.value || '').trim();
            if (resolvedMode === 'dark' || resolvedMode === 'light') {
              targetThemeModes.set(target.id, resolvedMode);
            }
          }
          await syncMetricsForSession(true);
          initialAttachDone = true;
          clearTimeout(attachTimeout);
          finishAttach(ok);
        });

        ws.addEventListener('message', (event) => {
          try {
            const msg = JSON.parse(String(event.data));
            if (msg.id && pendingCallbacks.has(msg.id)) {
              const cb = pendingCallbacks.get(msg.id);
              pendingCallbacks.delete(msg.id);
              cb(msg);
              return;
            }
            if (msg.method === 'Runtime.bindingCalled' && (!hostConfirmed || isSwarmIframe)) return;
            if (msg.method === 'Runtime.bindingCalled' && msg.params?.name === '__agRequestMetrics') {
              const nextIds = parseCascadeIdList(msg.params.payload);
              activeCascadeIds = nextIds;
              for (const existingCid of [...pushedSessions.keys()]) {
                if (!activeCascadeIds.includes(existingCid)) {
                  pushedSessions.delete(existingCid);
                }
              }
              if (activeCascadeIds.length > 0) {
                for (const cid of activeCascadeIds) {
                  const prev = pushedSessions.get(cid);
                  if (prev) pushedSessions.set(cid, { hash: '', pendingActive: prev.pendingActive });
                }
                syncMetricsForSession(true);
              }
              return;
            }
            if (msg.method === 'Runtime.bindingCalled' && msg.params?.name === '__agSyncHostThemeMode') {
              const nextMode = String(msg.params.payload || '').trim();
              if (nextMode === 'dark' || nextMode === 'light') {
                const prevMode = targetThemeModes.get(target.id);
                targetThemeModes.set(target.id, nextMode);
                if (prevMode !== nextMode) {
                  relayThemeModeToChildIframes(target.id, endpoint.channel, nextMode);
                }
              }
              return;
            }
            if (!initialAttachDone) return;
            if (
              msg.method === 'Page.frameNavigated' ||
              msg.method === 'Page.loadEventFired' ||
              msg.method === 'Page.domContentEventFired'
            ) {
              if (!msg.params?.frame || !msg.params.frame.parentId) {
                if (navDebounceTimer) clearTimeout(navDebounceTimer);
                navDebounceTimer = setTimeout(() => {
                  navDebounceTimer = null;
                  checkAndInject();
                }, 120);
              }
            }
          } catch {}
        });

        const closeHandler = () => {
          clearTimeout(attachTimeout);
          if (navDebounceTimer) {
            clearTimeout(navDebounceTimer);
            navDebounceTimer = null;
          }
          for (const [, cb] of pendingCallbacks) cb(null);
          pendingCallbacks.clear();
          if (attachedTargets.get(target.id)?.ws === ws) {
            attachedTargets.delete(target.id);
            targetThemeModes.delete(target.id);
          }
          finishAttach(false);
        };
        ws.addEventListener('close', closeHandler);
        ws.addEventListener('error', closeHandler);

        attachedTargets.set(target.id, {
          ws,
          send,
          updateNewDocScript,
          inject,
          checkAndInject,
          syncMetricsForSession,
          endpoint,
          isSwarmIframe,
          parentId: target.parentId || null,
          hostConfirmed,
          updateTargetUrl: (u) => {
            if (u) currentTargetUrl = u;
          }
        });
      } catch {
        clearTimeout(attachTimeout);
        finishAttach(false);
      }
    });
  }

  async function sync() {
    if (isSyncing) return;
    isSyncing = true;
    syncTickCount = (syncTickCount + 1) % 6000;
    try {
      const bundleChanged = bundleCtrl.rebuildBundleIfNeeded();
      const { activeConfig } = bundleCtrl.getState();
      const shouldHeartbeatCheck = bundleChanged || syncTickCount % 6 === 1;
      const nowMs = Date.now();
      const debuggerEndpoint = readDebuggerEndpoint(activeConfig.endpoint.portFile);
      const nextDebuggerEndpoint = debuggerEndpoint ? `${debuggerEndpoint.port}${debuggerEndpoint.browserPath}` : '';
      if (connectedDebuggerEndpoint !== nextDebuggerEndpoint) {
        closeAll();
        targetMetaMap.clear();
        skippedNonHostTargets.clear();
        connectedDebuggerEndpoint = nextDebuggerEndpoint;
      }
      const shouldDiscoverTargets =
        runOnce ||
        bundleChanged ||
        attachedTargets.size === 0 ||
        nowMs - lastTargetDiscoveryMs >= TARGET_DISCOVERY_INTERVAL_MS;

      if (!shouldDiscoverTargets) {
        for (const entry of attachedTargets.values()) {
          if (!entry.hostConfirmed) continue;
          if (shouldHeartbeatCheck && entry.checkAndInject) await entry.checkAndInject();
          if (entry.syncMetricsForSession) await entry.syncMetricsForSession(false);
        }
        return;
      }

      lastTargetDiscoveryMs = nowMs;
      const activeTargetIds = new Set();
      const seenRawTargetIds = new Set();
      const pendingPages = [];
      const pendingIframes = [];
      if (debuggerEndpoint) {
        const endpoint = { ...activeConfig.endpoint, ...debuggerEndpoint };
        const targets = await fetchTargets(debuggerEndpoint);
        for (const t of targets) {
          if (!t?.id) continue;
          seenRawTargetIds.add(t.id);
          targetMetaMap.set(t.id, { type: t.type, parentId: t.parentId || null, channel: endpoint.channel });
          const skipped = skippedNonHostTargets.get(t.id);
          if (skipped && (!isAllowedOrigin(t.url) || getTargetOriginKey(t.url) !== skipped.origin)) {
            skippedNonHostTargets.delete(t.id);
          }
        }

        const pages = targets.filter(
          (t) =>
            typeof t?.id === 'string' &&
            (t.type === 'page' || (t.type === 'iframe' && String(t.url || '').startsWith('plugin://swarm--'))) &&
            isAllowedDebuggerSocket(t.webSocketDebuggerUrl, endpoint.port) &&
            isAllowedOrigin(t.url) &&
            !String(t.title || '').includes('Launchpad') &&
            !isSkippedTargetCoolingDown(skippedNonHostTargets.get(t.id), getTargetOriginKey(t.url), nowMs)
        );

        for (const page of pages) {
          activeTargetIds.add(page.id);
          if (page.type === 'iframe') {
            pendingIframes.push({ page, endpoint });
          } else {
            pendingPages.push({ page, endpoint });
          }
        }
      }

      const syncTargetBatch = async (items) => {
        const attachPromises = [];
        for (const { page, endpoint } of items) {
          if (!attachedTargets.has(page.id)) {
            attachPromises.push(attachTarget(page, endpoint));
          } else {
            const entry = attachedTargets.get(page.id);
            entry.endpoint = endpoint;
            entry.parentId = page.parentId || entry.parentId || null;
            entry.updateTargetUrl?.(page.url);
            if (entry.hostConfirmed) {
              if (bundleChanged && entry.updateNewDocScript) {
                await entry.updateNewDocScript();
              }
              if (shouldHeartbeatCheck && entry.checkAndInject) await entry.checkAndInject();
              if (entry.syncMetricsForSession) await entry.syncMetricsForSession(bundleChanged);
            }
          }
        }
        if (attachPromises.length > 0) {
          await Promise.allSettled(attachPromises);
        }
      };

      await syncTargetBatch(pendingPages);
      await syncTargetBatch(pendingIframes);

      for (const [id, entry] of attachedTargets.entries()) {
        if (!activeTargetIds.has(id)) {
          try {
            entry.ws.close();
          } catch {}
          attachedTargets.delete(id);
          targetThemeModes.delete(id);
        }
      }
      if (seenRawTargetIds.size > 0) {
        for (const id of skippedNonHostTargets.keys()) {
          if (!seenRawTargetIds.has(id)) skippedNonHostTargets.delete(id);
        }
        for (const id of targetMetaMap.keys()) {
          if (!seenRawTargetIds.has(id)) targetMetaMap.delete(id);
        }
      } else if (attachedTargets.size === 0) {
        targetMetaMap.clear();
      }
    } finally {
      isSyncing = false;
    }
  }

  function closeAll() {
    for (const [, entry] of attachedTargets.entries()) {
      try {
        entry.ws.close();
      } catch {}
    }
    attachedTargets.clear();
    targetThemeModes.clear();
  }

  return { sync, closeAll };
}
