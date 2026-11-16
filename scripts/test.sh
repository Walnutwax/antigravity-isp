#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
BUILD_ARCH="$(uname -m)"
mkdir -p .build/module-cache
SWIFT_FLAGS=(-swift-version 5 -parse-as-library -target "$BUILD_ARCH-apple-macosx13.0" -module-cache-path "$PROJECT_DIR/.build/module-cache")
xcrun swiftc "${SWIFT_FLAGS[@]}" Sources/Models.swift Sources/CoreInstaller.swift Tests/TestMain.swift -o .build/model-tests
.build/model-tests
xcrun swiftc -swift-version 5 -module-cache-path "$PROJECT_DIR/.build/module-cache" Tests/FakeRelay.swift -o .build/fake-relay
xcrun swiftc "${SWIFT_FLAGS[@]}" -framework Cocoa Sources/Models.swift Sources/LauncherController.swift Tests/RuntimeTests.swift -o .build/runtime-tests
ANTIGRAVITY_ISP_HOME="$PROJECT_DIR/.build/runtime-test-home" .build/runtime-tests "$PROJECT_DIR/.build/fake-relay"
