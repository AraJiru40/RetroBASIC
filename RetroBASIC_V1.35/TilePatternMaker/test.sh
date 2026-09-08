#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
XCODE_DEVELOPER="/Applications/Xcode.app/Contents/Developer"
MODULE_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/tile-pattern-maker-test-module-cache.XXXXXX")"
trap 'rm -rf "$MODULE_CACHE"' EXIT

if [ -x "$XCODE_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" ]; then
    SWIFTC="$XCODE_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    SDK="$XCODE_DEVELOPER/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
else
    SWIFTC="$(xcrun --find swiftc)"
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$BUILD_DIR"

"$SWIFTC" \
    -Onone \
    -swift-version 5 \
    -target "$(uname -m)-apple-macosx13.0" \
    -sdk "$SDK" \
    -module-cache-path "$MODULE_CACHE" \
    "$PROJECT_DIR/Sources/TilePatternMaker/TilePattern.swift" \
    "$PROJECT_DIR/Tests/TilePatternLogicTests.swift" \
    -o "$BUILD_DIR/TilePatternLogicTests"

"$BUILD_DIR/TilePatternLogicTests"

"$SWIFTC" \
    -Onone \
    -parse-as-library \
    -D SNAPSHOT \
    -swift-version 5 \
    -target "$(uname -m)-apple-macosx13.0" \
    -sdk "$SDK" \
    -module-cache-path "$MODULE_CACHE" \
    "$PROJECT_DIR/Sources/TilePatternMaker/TilePattern.swift" \
    "$PROJECT_DIR/Sources/TilePatternMaker/main.swift" \
    "$PROJECT_DIR/Tests/AppInteractionTests.swift" \
    -o "$BUILD_DIR/AppInteractionTests" \
    -framework SwiftUI \
    -framework AppKit

"$BUILD_DIR/AppInteractionTests"
