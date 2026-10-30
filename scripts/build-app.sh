#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TRIPLE="arm64-apple-macosx14.4"
swift build -c release --triple "$TRIPLE"
BIN_DIR="$(swift build -c release --triple "$TRIPLE" --show-bin-path)"
APP="$ROOT/.build/LevelUp.app"
ICON="$ROOT/.build/generated-icon/LevelUp.icns"
"$ROOT/scripts/build-icon.sh"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SystemAudioPassThrough" "$APP/Contents/MacOS/SystemAudioPassThrough"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/LevelUp.icns"
codesign --force --sign - "$APP"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/SystemAudioPassThrough")"
if [[ "$ARCHS" != "arm64" ]]; then
    echo "error: expected arm64-only executable, got '$ARCHS'" >&2
    exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")" != "LevelUp.icns" ]]; then
    echo "error: app Info.plist does not reference LevelUp.icns" >&2
    exit 1
fi
if [[ ! -s "$APP/Contents/Resources/LevelUp.icns" ]]; then
    echo "error: app icon resource is missing or empty" >&2
    exit 1
fi
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
echo "Built and verified $APP ($ARCHS; icon=LevelUp.icns)"
