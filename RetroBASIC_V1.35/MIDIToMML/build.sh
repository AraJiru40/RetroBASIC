#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="MIDIToMML"
APP_DIR="$PROJECT_DIR/$APP_NAME.app"
BUILD_DIR="$PROJECT_DIR/build"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
XCODE_DEVELOPER="/Applications/Xcode.app/Contents/Developer"

if [ -x "$XCODE_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" ]; then
    SWIFTC="$XCODE_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    SDK="$XCODE_DEVELOPER/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
else
    SWIFTC="$(xcrun --find swiftc)"
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$BUILD_DIR/ModuleCache"

"$SWIFTC" \
    -O \
    -parse-as-library \
    -swift-version 5 \
    -target "$(uname -m)-apple-macosx13.0" \
    -sdk "$SDK" \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    "$PROJECT_DIR/Sources/MIDIToMML/MIDI.swift" \
    "$PROJECT_DIR/Sources/MIDIToMML/main.swift" \
    -o "$MACOS_DIR/$APP_NAME" \
    -framework SwiftUI \
    -framework AppKit

cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "$APP_DIR"
