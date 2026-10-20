#!/bin/bash
# RetroBASIC build script
#   ./build.sh        -> builds RetroBASIC.app and the CLI (retrobasic-cli)
set -e
cd "$(dirname "$0")"

APP=RetroBASIC.app
TARGET=arm64-apple-macosx13.0
RETROBASIC_XCODE_DEVELOPER=/Applications/Xcode.app/Contents/Developer
if [ -x "$RETROBASIC_XCODE_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" ]; then
    RETROBASIC_SWIFTC="$RETROBASIC_XCODE_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    RETROBASIC_SDK="$RETROBASIC_XCODE_DEVELOPER/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
else
    RETROBASIC_SWIFTC="$(xcrun --find swiftc)"
    RETROBASIC_SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi
RETROBASIC_MODULE_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/retrobasic-module-cache.XXXXXX")"
trap 'rm -rf "$RETROBASIC_MODULE_CACHE"' EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "== building GUI app =="
"$RETROBASIC_SWIFTC" -O -swift-version 5 -target "$TARGET" \
    -sdk "$RETROBASIC_SDK" -module-cache-path "$RETROBASIC_MODULE_CACHE" \
    Sources/RetroCharset.swift Sources/Console.swift Sources/PSG.swift Sources/Interpreter.swift \
    Sources/RetroFont.swift Sources/RetroFontKana.swift Sources/RetroFontGraph.swift \
    Sources/Terminal.swift Sources/CharacterPalette.swift Sources/SettingsWindow.swift Sources/App.swift \
    -o "$APP/Contents/MacOS/RetroBASIC" \
    -framework Cocoa -framework Carbon -framework AVFoundation
cp Info.plist "$APP/Contents/Info.plist"
if [ -f AppIcon.icns ]; then cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
codesign --force -s - "$APP" 2>/dev/null || true

echo "== building CLI =="
"$RETROBASIC_SWIFTC" -O -swift-version 5 -target "$TARGET" \
    -sdk "$RETROBASIC_SDK" -module-cache-path "$RETROBASIC_MODULE_CACHE" \
    Sources/RetroCharset.swift Sources/Console.swift Sources/PSG.swift Sources/Interpreter.swift Sources/CLIMain.swift \
    -o retrobasic-cli -framework AVFoundation

echo "done: $APP / retrobasic-cli"
