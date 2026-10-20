#!/bin/bash
# RetroBASIC test script
#   ./test.sh         -> builds and runs MMLTests and ScreenEditorTests
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
XCODE_DEVELOPER="/Applications/Xcode.app/Contents/Developer"
MODULE_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/retrobasic-test-module-cache.XXXXXX")"
trap 'rm -rf "$MODULE_CACHE"' EXIT

if [ -x "$XCODE_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" ]; then
    SWIFTC="$XCODE_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    SDK="$XCODE_DEVELOPER/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
else
    SWIFTC="$(xcrun --find swiftc)"
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$BUILD_DIR"

CORE_SOURCES=(
    "$PROJECT_DIR/Sources/RetroCharset.swift"
    "$PROJECT_DIR/Sources/Console.swift"
    "$PROJECT_DIR/Sources/PSG.swift"
    "$PROJECT_DIR/Sources/Interpreter.swift"
)

"$SWIFTC" \
    -Onone \
    -parse-as-library \
    -swift-version 5 \
    -target arm64-apple-macosx13.0 \
    -sdk "$SDK" \
    -module-cache-path "$MODULE_CACHE" \
    "${CORE_SOURCES[@]}" \
    "$PROJECT_DIR/Tests/MMLTests.swift" \
    -o "$BUILD_DIR/MMLTests" \
    -framework AVFoundation

"$BUILD_DIR/MMLTests"

"$SWIFTC" \
    -Onone \
    -parse-as-library \
    -swift-version 5 \
    -target arm64-apple-macosx13.0 \
    -sdk "$SDK" \
    -module-cache-path "$MODULE_CACHE" \
    "${CORE_SOURCES[@]}" \
    "$PROJECT_DIR/Sources/RetroFont.swift" \
    "$PROJECT_DIR/Sources/RetroFontKana.swift" \
    "$PROJECT_DIR/Sources/RetroFontGraph.swift" \
    "$PROJECT_DIR/Sources/Terminal.swift" \
    "$PROJECT_DIR/Sources/CharacterPalette.swift" \
    "$PROJECT_DIR/Sources/SettingsWindow.swift" \
    "$PROJECT_DIR/Tests/ScreenEditorTests.swift" \
    -o "$BUILD_DIR/ScreenEditorTests" \
    -framework Cocoa -framework Carbon -framework AVFoundation

"$BUILD_DIR/ScreenEditorTests"
