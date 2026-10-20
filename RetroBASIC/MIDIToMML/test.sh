#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
XCODE_DEVELOPER="/Applications/Xcode.app/Contents/Developer"
MODULE_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/midi-to-mml-test-module-cache.XXXXXX")"
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
    -warnings-as-errors \
    -swift-version 5 \
    -target "$(uname -m)-apple-macosx13.0" \
    -sdk "$SDK" \
    -module-cache-path "$MODULE_CACHE" \
    "$PROJECT_DIR/../Sources/PSG.swift" \
    "$PROJECT_DIR/Sources/MIDIToMML/MIDI.swift" \
    "$PROJECT_DIR/Tests/MIDIFixture.swift" \
    "$PROJECT_DIR/Tests/MIDIConversionTests.swift" \
    -o "$BUILD_DIR/MIDIConversionTests" \
    -framework AVFoundation

"$BUILD_DIR/MIDIConversionTests"

"$SWIFTC" \
    -Onone \
    -warnings-as-errors \
    -parse-as-library \
    -D SNAPSHOT \
    -swift-version 5 \
    -target "$(uname -m)-apple-macosx13.0" \
    -sdk "$SDK" \
    -module-cache-path "$MODULE_CACHE" \
    "$PROJECT_DIR/Sources/MIDIToMML/MIDI.swift" \
    "$PROJECT_DIR/Sources/MIDIToMML/main.swift" \
    "$PROJECT_DIR/Tests/MIDIFixture.swift" \
    "$PROJECT_DIR/Tests/AppInteractionTests.swift" \
    -o "$BUILD_DIR/AppInteractionTests" \
    -framework SwiftUI \
    -framework AppKit

"$BUILD_DIR/AppInteractionTests"
