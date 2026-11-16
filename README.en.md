# Antigravity ISP

[简体中文](README.md) · [Download v0.1.0 preview](https://github.com/Walnutwax/antigravity-isp/releases/tag/v0.1.0)

Give Antigravity its own proxy and launch it in one click while keeping your system proxy settings unchanged. Supports authenticated remote HTTP, HTTPS, and SOCKS5 proxies, without first starting a general-purpose proxy client yourself.

This native macOS launcher manages the local relay and starts the official Antigravity application with the appropriate proxy settings. Install Antigravity separately and bring your own upstream proxy.

This is an independent project with no affiliation with Antigravity. It provides no proxy service, accounts, or service entitlement, and makes no promises about account availability, regional eligibility, or server-side restrictions.

## How it works

```text
Antigravity + proxy-aware child processes
                    │
                    ▼
           127.0.0.1:17898
      Dedicated Mihomo relay process
                    │
                    ▼
       Your HTTP / HTTPS / SOCKS5 proxy
```

- Native Swift/AppKit interface with no Python runtime.
- Configurable upstream protocol, server, port, username, and password; passwords are stored in macOS Keychain.
- Manages a dedicated relay process, with a configurable local port, application path, and automatic launch when the launcher opens.
- Connection testing with an optional expected exit IP to compare against the test request's observed address.
- A regular Dock application with original project artwork.

The launcher does not enable TUN or modify system proxy settings or global environment variables. It is not a virtual machine or network isolation sandbox. Coverage depends on Antigravity and its children honoring the supplied proxy arguments or environment variables. External browsers, existing processes, and extensions or command-line tools that ignore proxy settings may use other network paths. A successful connection test establishes the route of that test request, not every request made by the application.

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
6. Save and test the configuration, then launch Antigravity through the launcher.

If Antigravity is already running, quit it normally before launching it here so that the new process receives the proxy settings. Automatic launch means starting the relay and target app when this launcher opens; it does not register a macOS login item.

Remove proxy endpoints, usernames, and passwords before sharing screenshots or logs in public issues.

## Data and proxy core

Settings and runtime files are kept in a dedicated per-user directory:

```text
~/Library/Application Support/AntigravityISP/
```

Passwords are stored in macOS Keychain with service `io.github.antigravity-isp.proxy` and account `default`. Mihomo needs the credentials while running, so a temporary configuration is written with `0600` permissions and removed during normal stop or exit. Forced termination or a system crash can interrupt cleanup.

After you click “安装代理内核” (Install proxy core), the launcher downloads the appropriate architecture from the [official Mihomo v1.19.34 release](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.34) and checks it against a SHA-256 value pinned in the code. The installed core lives in `bin/` under the directory above. Neither this repository nor the generated `.app` includes a Mihomo binary or real proxy credentials.

Mihomo is provided under GPLv3. See [third-party notices](THIRD_PARTY_NOTICES.md) for its source, license, and pinned version. This project's MIT license covers its own code and artwork; it does not relicense third-party components.

## Validation status

Public version 0.1.0 has completed the following on macOS 26.7.3 and Apple Silicon:

- An `arm64` build and local code-signature verification.
- Tests for the configuration model, private file permissions, core tamper detection, and runtime lifecycle using isolated test directories.
- Real Launch Services argument and environment passing, plus normal-exit cleanup, using a native test `.app`.
- Hands-on GUI checks for first launch, advanced settings, and empty-form validation.
- Downloading Mihomo v1.19.34 from the official source, verifying the pinned SHA-256, and successfully running the core.
- A connection test using this public version's runtime, the official Mihomo core, and a real remote upstream proxy. The expected exit IP matched, and no temporary credential configurations remained after stopping.

The public version's process-launch flow has been verified using a native test `.app`; end-to-end model requests in the real Antigravity application have not yet been verified for this version. Apple Silicon and Intel builds and automated tests passed in GitHub Actions. Interactive Intel use, real proxy connections on Intel, and actual macOS 13 runtime behavior remain unverified.

Prototype record: an earlier personal version was exercised with the real Antigravity 2.32.1 application in the same environment. That record is separate from the public-version validation above.

## Troubleshooting

**The first download fails:** Check that your current network can reach GitHub's official release assets, then retry. A core with a mismatched checksum is not used.

**The local port is occupied:** Choose an unused local port, save, and restart the relay.

**A relay or temporary configuration remains after a forced quit:** Force-quitting or a system crash may leave the launcher's relay process and temporary configuration behind. Verify that a process's executable belongs to this launcher's dedicated directory before handling it. The launcher does not automatically kill processes merely because they occupy a port; preserve other proxy clients and unrelated processes.

**The exit IP differs from the expected IP:** Check the upstream settings and your provider's routing policy. Some services rotate exit IPs; the expected value must match your service.

**The test succeeds but the application still fails:** Confirm that the application was restarted through the launcher and identify whether the request comes from an external browser, extension, or independent tool. Proxy connectivity does not establish account or service eligibility.

## Uninstall

Stop the relay and quit the launcher, then delete `Antigravity ISP.app`. To remove its saved data, delete `~/Library/Application Support/AntigravityISP/` and remove the password item with service `io.github.antigravity-isp.proxy` and account `default` using Keychain Access.

These belong exclusively to this launcher. Keep the official Antigravity application and its user data.

## Development

Application code is in [Sources](Sources), and build scripts are in [scripts](scripts). Run `./scripts/test.sh` and `./scripts/build.sh` after changes. Keep real credentials and personal configuration out of tests, examples, screenshots, and commits.

Original code and artwork are available under the [MIT license](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party components, product names, and trademarks.
