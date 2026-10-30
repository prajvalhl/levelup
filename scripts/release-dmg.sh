#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TRIPLE="arm64-apple-macosx14.4"
APP="$ROOT/.build/LevelUpPrototype.app"
EXECUTABLE="$APP/Contents/MacOS/SystemAudioPassThrough"
OUTPUT_DIR="$ROOT/release"
DMG="$OUTPUT_DIR/LevelUp.dmg"
STAGE="$ROOT/.build/release-staging.$$"
MOUNT="$ROOT/.build/release-mount.$$"
MOUNTED=0

cleanup() {
    if [[ "$MOUNTED" == "1" ]]; then
        hdiutil detach "$MOUNT" -quiet || true
    fi
    rm -rf "$STAGE" "$MOUNT"
}
trap cleanup EXIT

echo "Running ARM64 macOS test suite..."
swift test --triple "$TRIPLE"

echo "Building and verifying the app bundle..."
"$ROOT/scripts/build-app.sh"

[[ -d "$APP" ]] || { echo "error: app bundle missing: $APP" >&2; exit 1; }
[[ -x "$EXECUTABLE" ]] || { echo "error: executable missing or not executable: $EXECUTABLE" >&2; exit 1; }

ARCHS="$(lipo -archs "$EXECUTABLE")"
[[ "$ARCHS" == "arm64" ]] || { echo "error: expected ARM64-only executable, got '$ARCHS'" >&2; exit 1; }

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
BUNDLE_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
[[ "$BUNDLE_ID" == "com.levelup.prototype.system-audio-passthrough" ]] || { echo "error: unexpected bundle ID '$BUNDLE_ID'" >&2; exit 1; }
[[ "$BUNDLE_EXECUTABLE" == "SystemAudioPassThrough" ]] || { echo "error: unexpected CFBundleExecutable '$BUNDLE_EXECUTABLE'" >&2; exit 1; }
[[ "$MINIMUM_OS" == "14.4" ]] || { echo "error: unexpected minimum macOS version '$MINIMUM_OS'" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"

rm -rf "$STAGE" "$MOUNT"
mkdir -p "$STAGE" "$OUTPUT_DIR" "$MOUNT"
ditto "$APP" "$STAGE/LevelUp.app"
cmp "$APP/Contents/Resources/LevelUp.icns" "$STAGE/LevelUp.app/Contents/Resources/LevelUp.icns"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "LevelUp" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
hdiutil verify "$DMG"

hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT" -quiet
MOUNTED=1
[[ -d "$MOUNT/LevelUp.app" ]] || { echo "error: DMG does not contain LevelUp.app" >&2; exit 1; }
[[ -s "$MOUNT/LevelUp.app/Contents/Resources/LevelUp.icns" ]] || { echo "error: DMG app icon resource is missing or empty" >&2; exit 1; }
cmp "$APP/Contents/Resources/LevelUp.icns" "$MOUNT/LevelUp.app/Contents/Resources/LevelUp.icns"
DMG_ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$MOUNT/LevelUp.app/Contents/Info.plist")"
[[ "$DMG_ICON_NAME" == "LevelUp.icns" ]] || { echo "error: DMG app plist does not reference LevelUp.icns" >&2; exit 1; }
[[ -L "$MOUNT/Applications" ]] || { echo "error: DMG does not contain an Applications shortcut" >&2; exit 1; }
[[ "$(readlink "$MOUNT/Applications")" == "/Applications" ]] || { echo "error: Applications shortcut has an unexpected destination" >&2; exit 1; }
codesign --verify --deep --strict "$MOUNT/LevelUp.app"
hdiutil detach "$MOUNT" -quiet
MOUNTED=0

echo "Release image created and verified: $DMG"
echo "Architecture: $ARCHS"
echo "Bundle ID: $BUNDLE_ID"
echo "Minimum macOS: $MINIMUM_OS"
echo "Signature: ad-hoc only; not Developer ID signed or notarized"
du -h "$DMG"
