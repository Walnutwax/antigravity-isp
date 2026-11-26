# Antigravity ISP

[简体中文](README.md) · [Releases](https://github.com/Walnutwax/antigravity-isp/releases)

Give Antigravity its own proxy and launch it in one click while keeping your system proxy settings unchanged. Supports Clash/Mihomo subscriptions, authenticated HTTP/HTTPS/SOCKS5 proxies, chained encrypted landing (Subscription or VLESS Reality/TLS relay → static landing proxy), optional three-way model-traffic split routing, and custom direct-domain rules.

This native macOS launcher manages a dedicated local Mihomo relay and starts the official Antigravity application with the appropriate proxy settings. Install Antigravity separately and bring your own upstream proxy.

This is an independent project with no affiliation with Antigravity. It provides no proxy service, accounts, or service entitlement, and makes no promises about account availability, regional eligibility, or server-side restrictions.

## How it works

Default single-hop mode:

```text
Antigravity + proxy-aware child processes
                    │
                    ▼
           127.0.0.1:17898
  Dedicated Mihomo relay (Keep-Alive 15s)
                    ├── UDP → Reject
                    ├── Custom direct domains → Mac network / existing VPN
                    └── Other requests → Your subscription node or HTTP / HTTPS / SOCKS5 proxy
```

Optional chained encrypted landing & three-way split mode (via `dialer-proxy`):

```text
Antigravity + proxy-aware child processes
                    │
                    ▼
           127.0.0.1:17898
  Dedicated Mihomo relay (Keep-Alive 15s)
                    ├── UDP → Reject
                    ├── Exit probes & core AI/model domains → RELAY (Subscription or VLESS Reality/TLS) → UPSTREAM (static landing proxy)
                    ├── Custom direct domains → Mac network / existing VPN
                    └── Other requests → RELAY (when three-way split is enabled), otherwise UPSTREAM
```

- Native Swift/AppKit interface with no Python runtime.
- Configurable upstream protocol, server, port, username, and password; passwords, subscription URLs, and VLESS relay URIs are stored in macOS Keychain.
- Chained encrypted landing: use either a Clash/Mihomo subscription node or a self-hosted VLESS Reality/TLS node as the encrypted first hop (`RELAY`) dialing a static residential/ISP proxy (`UPSTREAM`) via `dialer-proxy`, reducing plaintext HTTP proxy connection resets.
- Optional three-way split routing in chained mode: route exit probes and core AI/model domains through the chained landing proxy (`UPSTREAM`), keep custom direct domains on `DIRECT`, and send remaining traffic directly through `RELAY`.
- TCP Keep-Alive enabled by default (`keep-alive-idle: 15`, `keep-alive-interval: 15`) to keep long-lived HTTP/2 and streaming connections alive across NATs and firewalls.
- Manages a dedicated relay process, with a configurable local port, application path, and automatic launch when the launcher opens.
- Connection testing with an optional expected exit IP to compare against the test request's observed address.
- Advanced settings for exact domains and domain suffixes that should connect directly. Both lists are empty by default.
- A regular Dock application with original project artwork.

The launcher does not enable TUN or modify system proxy settings or global environment variables. Proxy arguments and environment variables apply only to applications started through this launcher and their children; coverage depends on each process honoring them. External browsers, existing processes, Git over native TCP/SSH, and extensions or command-line tools that ignore proxy settings are outside this coverage.

The exit IP is checked during connection tests and before application launch. There is no system-wide network blocking or continuous IP monitoring. A successful check establishes the test request's exit at that moment, not the route of every application request.

## Requirements

- macOS 13 or later.
- The official Antigravity App or Antigravity IDE, installed separately.
- A working Clash/Mihomo subscription or an HTTP, HTTPS, or SOCKS5 upstream proxy (optionally paired with a subscription or self-hosted VLESS Reality/TLS relay for chained landing).
- Your Mac's current network must reach GitHub for the first core installation; the download does not use the local relay that has yet to start. Later launches can use the verified local core.
- Xcode Command Line Tools for source builds; install with `xcode-select --install`.

## Build from source

Run from this repository:

```sh
./scripts/test.sh
./scripts/build.sh
open "dist/Antigravity ISP.app"
```

The output is `dist/Antigravity ISP.app`; drag it into Applications if desired. Building does not download a proxy core, require Python, or use proxy credentials. The script invokes the system Swift compiler in Swift 5 language mode, linking Cocoa/AppKit and Security.

The default build targets the current Mac's architecture: `arm64` on Apple Silicon or `x86_64` on Intel. It is not a universal binary. CI tests and builds on GitHub's `macos-15` and `macos-15-intel` runners, producing a ZIP and SHA-256 file per architecture.

Builds currently have only a local ad-hoc signature, with no Developer ID signing or Apple notarization. Gatekeeper may block downloaded builds. After verifying that you trust the source and contents, follow macOS's “Open Anyway” flow in System Settings → Privacy & Security, or inspect and build the source yourself.

## Configure and launch

1. On first use, click “安装代理内核” (Install proxy core) and wait for the pinned Mihomo download and checksum verification. This step reaches GitHub using your Mac's current network.
2. Select the installed Antigravity App or Antigravity IDE. Use the custom application picker to select an `.app` at another location.
3. Choose **Subscription** or **Manual Proxy**:
   - **Single-hop subscription**: paste a Clash/Mihomo feed URL, click “刷新节点” (Refresh Nodes), and pick a node or leave automatic selection enabled.
   - **Subscription-chained landing**: in Subscription mode, enable “链式落地” (Chained landing via `dialer-proxy`) and fill in your static landing proxy below.
   - **Single-hop manual proxy**: enter the protocol, server, port, and credentials (or import from clipboard).
   - **VLESS Reality/TLS chained landing**: in Manual Proxy mode, enable “启用加密中转节点” (Encrypted relay node), paste your `vless://` Reality/TLS URI, and fill in your static landing proxy below.
4. When either chained mode is enabled, optionally enable “链式三路分流” (Three-way split routing) so only AI/model traffic uses the landing proxy while other traffic exits directly through the relay hop.
5. Keep the default local port `17898`, or choose another unused port. Optionally enter an expected exit IP.
6. If you need direct access to specific local or private-network domains, add them in Advanced Settings; otherwise leave both fields empty.
7. Save and test the configuration, then launch Antigravity through the launcher.

If Antigravity is already running, quit it normally before launching it here so that the new process receives the proxy settings. Automatic launch means starting the relay and target app when this launcher opens; it does not register a macOS login item.

While Antigravity is running through the launcher, edit the two direct-domain fields in Advanced Settings and click 应用分流 (Apply Routing). The launcher validates the candidate configuration, saves the lists, and requests a reload in the same relay process. New rules apply to subsequent connections. Existing connections may keep their route until they reconnect. Stop the session before changing the upstream proxy, chaining mode, expected exit IP, or listening port.

Remove proxy endpoints, credentials, relay URIs, and subscription links before sharing screenshots or logs in public issues.

## Subscriptions and node selection

1. Paste the subscription URL and click “刷新节点” (Refresh Nodes).
2. Choose a node or leave automatic latency-based selection enabled, then test the connection or start Antigravity.

Automatic selection can switch nodes as their measured latency changes. For a fixed exit, select a named node and enter the expected exit IP, or chain the subscription into a static landing proxy.

The launcher accepts Clash/Mihomo YAML, including Base64-encoded YAML. A feed consisting only of raw node links is unsupported. The launcher fetches the feed before starting Mihomo and can use the configured manual proxy for that download. Prefer HTTPS for feeds containing access tokens. Redirect targets must use HTTPS.

Tests and launches reuse a private cache for up to 10 minutes. Refresh Nodes downloads a fresh copy and can be cancelled. The running relay uses the node list retrieved at session start. The subscription URL is kept in Keychain, and the private node catalog stores its SHA-256 fingerprint.

## Chained encrypted landing & three-way split

If your static residential/ISP proxy only exposes a plaintext HTTP endpoint, connecting directly across long-haul links can suffer from TCP resets (RST) or jitter. You can place an encrypted relay (`RELAY`) in front of it so Mihomo dials the landing proxy (`UPSTREAM`) over `dialer-proxy`:

- **Subscription relay**: enable chained landing in Subscription mode and configure your static landing proxy below.
- **Self-hosted VLESS Reality / TLS relay**: enable the encrypted relay option in Manual Proxy mode and paste a `vless://` URI (`type=tcp`, `security=reality` or `security=tls`). The URI is saved in macOS Keychain under account `relay-uri` and never written to `settings.json`.

A sanitized server template is included at [examples/xray-reality-server.example.json](examples/xray-reality-server.example.json). Two server-side details are critical for compatibility:

- **Pin Xray-core to `v26.6.27`**: with the pinned Mihomo `v1.19.34` core, `Xray-core v26.7.11+` enforces a stricter Reality `minClientVer` check that rejects current Mihomo handshakes.
- **Disable inbound sniffing (`"sniffing": {"enabled": false}`)**: enabling HTTP/TLS sniffing on the Xray inbound rewrites the destination of chained plaintext HTTP `CONNECT` hops and causes landing timeouts.

When three-way split routing is enabled in chained mode, Mihomo matches rules in order:

1. UDP requests use `REJECT`.
2. Exit-check probes (`api.ipify.org`, `www.cloudflare.com`, `api.myip.com`, `ifconfig.me`) and core AI/model domains (Google, Antigravity, Anthropic, OpenAI) route through `UPSTREAM` (chained landing proxy).
3. Explicitly configured exact domains and domain suffixes use `DIRECT`.
4. All remaining traffic uses `MATCH,RELAY` (exiting directly via the encrypted relay hop).

## Codex Theme, Chinese localization, and conversation stats

Select the standalone Antigravity App in the launcher and enable Codex Theme, localization, and conversation stats before launching. This optional feature requires Node.js 22.13 or later. Leave the path blank for automatic discovery, or enter the absolute path of the Node.js executable. Antigravity IDE continues to use the proxy features.

The bar below the message box shows time to first token, context usage, and output speed. Hover over it to see the number of completed compactions next to the current context. The count includes older completed checkpoints whose summaries have been pruned.

The launcher manages the theme alongside Antigravity. The theme connects to the launched application's local debugging port and reads conversation statistics in read-only mode. See [third-party notices](THIRD_PARTY_NOTICES.md) for its source and license.

## Custom direct-domain routing

Advanced settings provide two fields, both empty by default. Separate multiple domains with commas, spaces, or line breaks:

| Field | Settings key | Example and matching scope |
| --- | --- | --- |
| 精确直连域名 (Exact direct domains) | `directDomains` | `portal.example.com` matches only that hostname |
| 直连域名后缀 (Direct domain suffixes) | `directDomainSuffixes` | `internal.example.org` matches that domain and its subdomains |

Enter hostnames without schemes, paths, or wildcards. Add only local or private-network domains you explicitly intend to connect to directly. Validation rejects direct-routing entries for known model service domains. That list does not cover every current or future service domain and is not a complete network isolation guarantee.

In default single-hop mode (or chained mode without three-way split), requests entering the local Mihomo relay match these rules in order:

1. UDP requests use `REJECT`.
2. Exit-check domains `api.ipify.org`, `www.cloudflare.com`, `api.myip.com`, and `ifconfig.me` always use `UPSTREAM`, regardless of direct-routing settings. Connection checks probe them in parallel.
3. Explicitly configured exact domains and domain suffixes use `DIRECT`.
4. All remaining requests use `MATCH,UPSTREAM`, with no fallback to `DIRECT` if the upstream fails.

Direct requests use your Mac's system DNS and current local network (including any active private VPN). CLI commands and tools reach these routing rules only when they honor the supplied proxy settings; routing does not replace authentication or authorization.

When a model reads content from a local or private service, a local tool typically retrieves it through the direct route, then sends the relevant content to the model service through the upstream proxy. These are two network paths: configuring a direct route does not mean that content stays on the Mac.

## Data and proxy core

Settings and runtime files are kept in a dedicated per-user directory:

```text
~/Library/Application Support/AntigravityISP/
```

Sensitive credentials are stored in macOS Keychain under service `io.github.antigravity-isp.proxy`:

- `default`: manual upstream / landing proxy password
- `subscription`: Clash/Mihomo subscription URL
- `relay-uri`: VLESS Reality/TLS relay URI

Temporary relay configurations and node files use `0600` permissions. Normal exit removes them, and the launcher checks its runtime directory for recoverable leftovers on the next start.

After you click “安装代理内核” (Install proxy core), the launcher downloads the appropriate architecture from the [official Mihomo v1.19.34 release](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.34) and checks it against a SHA-256 value pinned in the code. The installed core lives in `bin/` under the directory above. Neither this repository nor the generated `.app` includes a Mihomo binary or real proxy credentials.

Mihomo is provided under GPLv3. See [third-party notices](THIRD_PARTY_NOTICES.md) for its source, license, and pinned version. This project's MIT license covers its own code and artwork; it does not relicense third-party components.

## Validation status

Version `0.6.0` passed locally on Apple Silicon:

- Full `./scripts/test.sh` model and runtime test suite covering VLESS Reality/TLS URI parsing and validation, subscription-chained landing, VLESS-chained landing, three-way split routing, TCP Keep-Alive 15s, legacy settings migration, domain validation, `0600` permissions, and runtime session cleanup.
- `node --test Tests/ThemeTests.mjs` theme and conversation metrics tests.
- Real Mihomo `v1.19.33` configuration validation (`-t`) on generated subscription-chained and VLESS Reality three-way split configs.
- `./scripts/build.sh` `arm64` build, `Info.plist` lint, and strict ad-hoc code-signature verification.

Earlier release records (`v0.1.0`–`v0.5.0`) are available on the [Releases page](https://github.com/Walnutwax/antigravity-isp/releases). Interactive Intel use and actual macOS 13 runtime behavior remain unverified locally; dual-architecture builds and automated tests are covered by GitHub Actions.

## Troubleshooting

**The first download fails:** Check that your current network can reach GitHub's official release assets, then retry. A core with a mismatched checksum is not used.

**Self-hosted VLESS Reality relay fails to handshake or chained landing times out:** Verify the server is running `Xray-core v26.6.27` (`v26.7.11+` rejects Mihomo `v1.19.34` Reality handshakes due to `minClientVer`) and that inbound `"sniffing": {"enabled": false}` is disabled.

**The local port is occupied:** Choose an unused local port, save, and restart the relay.

**A relay or temporary configuration remains after a forced quit:** Force-quitting or a system crash may leave the launcher's relay process and temporary configuration behind. Verify that a process's executable belongs to this launcher's dedicated directory before handling it. The launcher does not automatically kill processes merely because they occupy a port; preserve other proxy clients and unrelated processes.

**The exit IP differs from the expected IP:** Check the upstream settings and your provider's routing policy. Some services rotate exit IPs; the expected value must match your service.

**The test succeeds but the application still fails:** Confirm that the application was restarted through the launcher and identify whether the request comes from an external browser, extension, or independent tool. Proxy connectivity does not establish account or service eligibility.

**A custom direct site or private tool cannot connect:** First check that your Mac is on the required local network or VPN, system DNS can resolve the hostname, and any required authentication is complete. Then check the direct-domain match and whether the requesting tool honors proxy settings.

## Uninstall

Stop the relay and quit the launcher, then delete `Antigravity ISP.app`. To remove its saved data, delete `~/Library/Application Support/AntigravityISP/` and remove the Keychain items for service `io.github.antigravity-isp.proxy` and accounts `default`, `subscription`, and `relay-uri` using Keychain Access.

These belong exclusively to this launcher. Keep the official Antigravity application and its user data.

## Development

Application code is in [Sources](Sources), and build scripts are in [scripts](scripts). Run `./scripts/test.sh` and `./scripts/build.sh` after changes. Keep real credentials and personal configuration out of tests, examples, screenshots, and commits.

Original code and artwork are available under the [MIT license](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party components, product names, and trademarks.
