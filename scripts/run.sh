#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

case "${1:-}" in
  --help|-h)
    echo "Usage: ./scripts/run.sh [--check]"
    echo "Build and open Antigravity ISP. Use --check to inspect local prerequisites only."
    exit 0
    ;;
  ""|--check) ;;
  *) echo "Unknown option: $1. Use --help for usage." >&2; exit 1 ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Antigravity ISP requires macOS 13 or later." >&2
  exit 1
fi

if ! xcrun --find swiftc >/dev/null 2>&1 || ! xcrun --show-sdk-path >/dev/null 2>&1; then
  echo "Install Xcode Command Line Tools first: xcode-select --install" >&2
  exit 1
fi

echo "macOS $(sw_vers -productVersion) / $(uname -m); Swift compiler and SDK ready."
if [[ -d "/Applications/Antigravity.app" || -d "$HOME/Applications/Antigravity.app" ]]; then
  echo "Antigravity found."
else
  echo "Install Antigravity separately, or select its .app location in the launcher."
fi

SUPPORT_DIR="${ANTIGRAVITY_ISP_HOME:-$HOME/Library/Application Support/AntigravityISP}"
if [[ -x "$SUPPORT_DIR/bin/mihomo" ]]; then
  echo "Proxy core found."
else
  echo "The launcher will install the proxy core on the first test or launch; offline .gz import is also available."
fi
if [[ -f "$SUPPORT_DIR/settings.json" ]]; then
  echo "Saved settings found; credentials are not printed."
else
  echo "Enter your proxy details or import a proxy URL from the clipboard in the launcher."
fi

if [[ "${1:-}" == "--check" ]]; then
  exit 0
fi

./scripts/build.sh
/usr/bin/open "$PROJECT_DIR/dist/Antigravity ISP.app"
