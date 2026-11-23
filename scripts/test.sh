#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
case "${1:-}" in
  ""|--gui) ;;
  *) echo "Usage: ./scripts/test.sh [--gui]" >&2; exit 1 ;;
esac
BUILD_ARCH="$(uname -m)"
mkdir -p .build/module-cache
SWIFT_FLAGS=(-swift-version 5 -parse-as-library -target "$BUILD_ARCH-apple-macosx13.0" -module-cache-path "$PROJECT_DIR/.build/module-cache")
xcrun swiftc "${SWIFT_FLAGS[@]}" Sources/Models.swift Sources/ProxyImport.swift Sources/CoreInstaller.swift Sources/RelayConfiguration.swift Sources/Subscription.swift Tests/TestMain.swift -o .build/model-tests
.build/model-tests
xcrun swiftc -swift-version 5 -module-cache-path "$PROJECT_DIR/.build/module-cache" Tests/FakeRelay.swift -o .build/fake-relay
xcrun swiftc "${SWIFT_FLAGS[@]}" -framework Cocoa Sources/Models.swift Sources/CoreInstaller.swift Sources/RelayConfiguration.swift Sources/Subscription.swift Sources/ApplicationLocator.swift Sources/LauncherController.swift Tests/RuntimeTests.swift -o .build/runtime-tests
FIXTURE_ARGS=()
if [[ "${1:-}" == "--gui" ]]; then
  FIXTURE_DIR="$PROJECT_DIR/.build/ISP Test Application.app"
  mkdir -p "$FIXTURE_DIR/Contents/MacOS"
  xcrun swiftc "${SWIFT_FLAGS[@]}" -framework Cocoa Tests/FakeApplication.swift -o "$FIXTURE_DIR/Contents/MacOS/ISPTestApplication"
  cp Tests/FakeApplication-Info.plist "$FIXTURE_DIR/Contents/Info.plist"
  /usr/bin/codesign --force --sign - "$FIXTURE_DIR"
  FIXTURE_ARGS=("$FIXTURE_DIR")
fi
ANTIGRAVITY_ISP_HOME="$PROJECT_DIR/.build/runtime-test-home" .build/runtime-tests "$PROJECT_DIR/.build/fake-relay" ${FIXTURE_ARGS[@]+"${FIXTURE_ARGS[@]}"}
