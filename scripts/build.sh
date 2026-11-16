#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Antigravity ISP must be built on macOS with Xcode Command Line Tools." >&2
  exit 1
fi

BUILD_ARCH="$(uname -m)"
case "$BUILD_ARCH" in
  arm64|x86_64) ;;
  *) echo "Unsupported build architecture: $BUILD_ARCH" >&2; exit 1 ;;
esac

shopt -s nullglob
SOURCES=(Sources/*.swift)
if [[ ${#SOURCES[@]} -eq 0 ]]; then
  echo "No Swift sources found in Sources/." >&2
  exit 1
fi

mkdir -p .build/module-cache dist
STAGING_DIR="$(mktemp -d "$ROOT_DIR/.build/package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_DIR="$STAGING_DIR/Antigravity ISP.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

xcrun swiftc \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -target "$BUILD_ARCH-apple-macosx13.0" \
  -module-cache-path "$ROOT_DIR/.build/module-cache" \
  -framework Cocoa \
  -framework Security \
  "${SOURCES[@]}" \
  -o "$APP_DIR/Contents/MacOS/AntigravityISP"

cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP_DIR/Contents/Resources/"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
xcrun swift -module-cache-path "$ROOT_DIR/.build/module-cache" \
  scripts/generate-icon.swift "$STAGING_DIR/AppIcon.iconset"
/usr/bin/iconutil --convert icns --output "$APP_DIR/Contents/Resources/AppIcon.icns" \
  "$STAGING_DIR/AppIcon.iconset"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"

# A local ad-hoc signature permits normal local execution. It is not a
# Developer ID signature or Apple notarization.
/usr/bin/codesign --force --sign - "$APP_DIR"
/usr/bin/codesign --verify --strict "$APP_DIR"

rm -rf "$ROOT_DIR/dist/Antigravity ISP.app"
mv "$APP_DIR" "$ROOT_DIR/dist/Antigravity ISP.app"
echo "Built dist/Antigravity ISP.app ($BUILD_ARCH, macOS 13.0+, ad-hoc signed)"
