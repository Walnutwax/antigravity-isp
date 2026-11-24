# Third-party notices

## Antigravity ISP

Original launcher code, documentation, and generated icon artwork in this repository are licensed under the [MIT license](LICENSE), copyright © 2026 Antigravity ISP contributors. The icon is drawn from basic geometric shapes by [scripts/generate-icon.swift](scripts/generate-icon.swift); it does not use an official Antigravity icon.

## Mihomo

Mihomo is a separate proxy core maintained by MetaCubeX and its contributors. Antigravity ISP starts the core as a separate process and communicates with it over a local loopback proxy.

- Project: [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo)
- Pinned version: [v1.19.34](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.34)
- Corresponding source tree: [v1.19.34 source](https://github.com/MetaCubeX/mihomo/tree/v1.19.34)
- Source archive: [v1.19.34 tar.gz](https://github.com/MetaCubeX/mihomo/archive/refs/tags/v1.19.34.tar.gz)
- License: [GNU General Public License, version 3](https://github.com/MetaCubeX/mihomo/blob/v1.19.34/LICENSE)
- Upstream build configuration: [Makefile at v1.19.34](https://github.com/MetaCubeX/mihomo/blob/v1.19.34/Makefile)

No Mihomo executable is committed to this repository or included in the app bundle produced by `scripts/build.sh`. On first use, the launcher retrieves the appropriate official release asset, checks it against the SHA-256 value pinned in its source, and installs it in the user's dedicated Application Support directory.

The pinned source and upstream build configuration identify the code used for this dependency and provide a starting point for rebuilding it. This project does not claim byte-for-byte reproducibility of upstream release binaries.

The launcher's MIT license does not apply to Mihomo or alter its GPLv3 license. If you redistribute Mihomo, including by adding its binary to a modified application package, you must meet the applicable license requirements, including the requirements for providing the corresponding source. Review the upstream license and notices for the version you distribute.

## Antigravity Codex Theme

The optional interface enhancement bundles a subset of [nkjDSLcvanv/antigravity-codex-theme](https://github.com/nkjDSLcvanv/antigravity-codex-theme) at commit [`8d6730f`](https://github.com/nkjDSLcvanv/antigravity-codex-theme/commit/8d6730fff452dca554fbe152caa4b40c3d386285). The original copyright and MIT license are included in [Resources/CodexTheme/LICENSE](Resources/CodexTheme/LICENSE). Antigravity ISP manages the theme process and adds the completed-compaction display.

The optional feature uses a separately installed Node.js runtime. Node.js is distributed separately by the [Node.js project](https://nodejs.org/).

## Antigravity and Apple platforms

The official Antigravity application is installed separately and is not distributed by this project. Antigravity and other product names are the property of their respective owners. This project is not affiliated with or endorsed by those owners.

The launcher uses Swift and macOS system frameworks supplied by Apple. These are governed by their respective terms and are not relicensed by this repository.
