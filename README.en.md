# Antigravity ISP

[简体中文](README.md) · [Download v0.3.0 preview](https://github.com/Walnutwax/antigravity-isp/releases/tag/v0.3.0)

Give Antigravity its own proxy and launch it in one click while keeping your system proxy settings unchanged. Supports authenticated remote HTTP, HTTPS, and SOCKS5 proxies, with optional direct routing for company domains through your Mac's network, without first starting a general-purpose proxy client yourself.

This native macOS launcher manages the local relay and starts the official Antigravity application with the appropriate proxy settings. Install Antigravity separately and bring your own upstream proxy.

This is an independent project with no affiliation with Antigravity. It provides no proxy service, accounts, or service entitlement, and makes no promises about account availability, regional eligibility, or server-side restrictions.

## How it works

```text
Antigravity + proxy-aware child processes
                    │
                    ▼
           127.0.0.1:17898
      Dedicated Mihomo relay process
                    ├── UDP → Reject
                    ├── Explicit company domains → Mac network / company VPN
                    └── Other requests → Your HTTP / HTTPS / SOCKS5 proxy
```

- Native Swift/AppKit interface with no Python runtime.
- Configurable upstream protocol, server, port, username, and password; passwords are stored in macOS Keychain.
- Manages a dedicated relay process, with a configurable local port, application path, and automatic launch when the launcher opens.
- Connection testing with an optional expected exit IP to compare against the test request's observed address.
- Advanced settings for exact domains and domain suffixes that should connect directly. Both lists are empty by default; other requests use the upstream proxy.
- A regular Dock application with original project artwork.

The launcher does not enable TUN or modify system proxy settings or global environment variables. Proxy arguments and environment variables apply only to applications started through this launcher and their children; coverage depends on each process honoring them. External browsers, existing processes, Git over native TCP/SSH, and extensions or command-line tools that ignore proxy settings are outside this coverage.

The exit IP is checked during connection tests and before application launch. There is no system-wide network blocking or continuous IP monitoring. A successful check establishes the test request's exit at that moment, not the route of every application request.

## Requirements

- macOS 13 or later.
- The official Antigravity application, installed separately.
- A working HTTP, HTTPS, or SOCKS5 upstream proxy.
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

The default build targets the current Mac's architecture: `arm64` on Apple Silicon or `x86_64` on Intel. It is not a universal binary. CI tests and builds on GitHub's `macos-15` and `macos-15-intel` runners, producing a ZIP and SHA-256 file per architecture. Both architectures passed the first [build and test run](https://github.com/Walnutwax/antigravity-isp/actions/runs/43839326800).

Builds currently have only a local ad-hoc signature, with no Developer ID signing or Apple notarization. Gatekeeper may block downloaded builds. After verifying that you trust the source and contents, follow macOS's “Open Anyway” flow in System Settings → Privacy & Security, or inspect and build the source yourself.

## Configure and launch

1. On first use, click “安装代理内核” (Install proxy core) and wait for the pinned Mihomo download and checksum verification. This step reaches GitHub using your Mac's current network.
2. Select the installed Antigravity `.app` path.
3. Enter your upstream protocol, server, and port; supply a username and password if required.
4. Keep the default local port `17898`, or choose another unused port.
5. Optionally enter an expected exit IP. Leave it empty to inspect the observed address without comparing it.
6. If you need company network access, add direct domains in advanced settings as described below; otherwise leave both fields empty.
7. Save and test the configuration, then launch Antigravity through the launcher.

If Antigravity is already running, quit it normally before launching it here so that the new process receives the proxy settings. Automatic launch means starting the relay and target app when this launcher opens; it does not register a macOS login item.

While Antigravity is running through the launcher, edit the two direct-domain fields in Advanced Settings and click 应用分流 (Apply Routing). The launcher validates the candidate configuration, saves the lists, and requests a reload in the same relay process. New rules apply to subsequent connections. Existing connections may keep their route until they reconnect. Stop the session before changing the upstream proxy, expected exit IP, or listening port.

Remove proxy endpoints, usernames, and passwords before sharing screenshots or logs in public issues.

## Company networks and domain routing

Advanced settings provide two fields, both empty by default. Separate multiple domains with commas, spaces, or line breaks:

| Field | Settings key | Example and matching scope |
| --- | --- | --- |
| 精确直连域名 (Exact direct domains) | `directDomains` | `portal.example.com` matches only that hostname |
| 直连域名后缀 (Direct domain suffixes) | `directDomainSuffixes` | `corp.example.org` matches that domain and its subdomains |

Enter hostnames without schemes, paths, or wildcards. Add only company domains you explicitly intend to connect to directly. Validation rejects direct-routing entries for known model service domains. That list does not cover every current or future service domain and is not a complete network isolation guarantee.

Requests entering the local Mihomo relay match these rules in order:

1. UDP requests use `REJECT`.
2. Exit-check domains `api.ipify.org` and `www.cloudflare.com` always use `UPSTREAM`, regardless of direct-routing settings.
3. Explicitly configured exact domains and domain suffixes use `DIRECT`.
4. All remaining requests use `MATCH,UPSTREAM`, with no fallback to `DIRECT` if the upstream fails.

Direct company requests use your Mac's system DNS and current company network. You still need the required VPN, SSO, and access permissions. CLI commands and tools reach these routing rules only when they honor the supplied proxy settings; routing does not replace authentication or authorization.

When a model reads internal content, a local tool typically retrieves it through the company network, then sends the relevant content to the model service through the upstream proxy. These are two network paths: configuring a direct route does not mean internal content stays on the Mac.

## Data and proxy core

Settings and runtime files are kept in a dedicated per-user directory:

```text
~/Library/Application Support/AntigravityISP/
```

Passwords are stored in macOS Keychain with service `io.github.antigravity-isp.proxy` and account `default`. Mihomo needs the credentials while running, so a temporary configuration is written with `0600` permissions and removed during normal stop or exit. Forced termination or a system crash can interrupt cleanup.

After you click “安装代理内核” (Install proxy core), the launcher downloads the appropriate architecture from the [official Mihomo v1.19.34 release](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.34) and checks it against a SHA-256 value pinned in the code. The installed core lives in `bin/` under the directory above. Neither this repository nor the generated `.app` includes a Mihomo binary or real proxy credentials.

Mihomo is provided under GPLv3. See [third-party notices](THIRD_PARTY_NOTICES.md) for its source, license, and pinned version. This project's MIT license covers its own code and artwork; it does not relicense third-party components.

## Validation status

An existing local configuration has been exercised with direct access to an internal company service and simultaneous access to Google services through the upstream proxy. This verifies those local routes; it is not a full real-Antigravity regression test of the v0.2.0 public Swift build.

Version 0.2.0 passed the following locally on Apple Silicon:

- Automated tests for legacy settings migration, domain validation, rule priority, configuration permissions, and runtime lifecycle.
- Configuration validation with real Mihomo v1.19.34, plus 10 TCP routing checks and a UDP rejection check. Local mock upstream and destination services cover exact matching, suffix boundaries, default upstream routing, and exit-probe priority without external requests.
- An `arm64` build, signature verification, and hands-on advanced-settings checks, including rejection of model-service domains in the direct list.

See the [release record](https://github.com/Walnutwax/antigravity-isp/releases/tag/v0.2.0) for dual-architecture CI and downloads. Full model requests and internal-tool workflows in the real Antigravity application have not yet received end-to-end regression testing with this public build.

As the earlier validation baseline, public version 0.1.0 completed the following on macOS 26.7.3 and Apple Silicon:

- An `arm64` build and local code-signature verification.
- Tests for the configuration model, private file permissions, core tamper detection, and runtime lifecycle using isolated test directories.
- Real Launch Services argument and environment passing, plus normal-exit cleanup, using a native test `.app`.
- Hands-on GUI checks for first launch, advanced settings, and empty-form validation.
- Downloading Mihomo v1.19.34 from the official source, verifying the pinned SHA-256, and successfully running the core.
- A connection test using this public version's runtime, the official Mihomo core, and a real remote upstream proxy. The expected exit IP matched, and no temporary credential configurations remained after stopping.

The process-launch flow above was verified using a native test `.app`; Apple Silicon and Intel builds and automated tests also passed in GitHub Actions. Interactive Intel use, real proxy connections on Intel, and actual macOS 13 runtime behavior remain unverified.

Prototype record: an earlier personal version was exercised with the real Antigravity 2.32.1 application in the same environment. That record is separate from the public-version validation above.

## Troubleshooting

**The first download fails:** Check that your current network can reach GitHub's official release assets, then retry. A core with a mismatched checksum is not used.

**The local port is occupied:** Choose an unused local port, save, and restart the relay.

**A relay or temporary configuration remains after a forced quit:** Force-quitting or a system crash may leave the launcher's relay process and temporary configuration behind. Verify that a process's executable belongs to this launcher's dedicated directory before handling it. The launcher does not automatically kill processes merely because they occupy a port; preserve other proxy clients and unrelated processes.

**The exit IP differs from the expected IP:** Check the upstream settings and your provider's routing policy. Some services rotate exit IPs; the expected value must match your service.

**The test succeeds but the application still fails:** Confirm that the application was restarted through the launcher and identify whether the request comes from an external browser, extension, or independent tool. Proxy connectivity does not establish account or service eligibility.

**A company page or tool cannot connect:** First check that your Mac is on the required company network or VPN, system DNS can resolve the hostname, and SSO is complete. Then check the direct-domain match and whether the requesting tool honors proxy settings.

## Uninstall

Stop the relay and quit the launcher, then delete `Antigravity ISP.app`. To remove its saved data, delete `~/Library/Application Support/AntigravityISP/` and remove the password item with service `io.github.antigravity-isp.proxy` and account `default` using Keychain Access.

These belong exclusively to this launcher. Keep the official Antigravity application and its user data.

## Development

Application code is in [Sources](Sources), and build scripts are in [scripts](scripts). Run `./scripts/test.sh` and `./scripts/build.sh` after changes. Keep real credentials and personal configuration out of tests, examples, screenshots, and commits.

Original code and artwork are available under the [MIT license](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party components, product names, and trademarks.
