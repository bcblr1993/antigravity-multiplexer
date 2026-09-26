#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP='Antigravity 多开管理器.app'
swift build -c release --triple arm64-apple-macosx13.0
BIN_DIR="$(swift build -c release --triple arm64-apple-macosx13.0 --show-bin-path)"
SPARKLE='.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
[[ -d "$SPARKLE" ]] || { echo 'Sparkle.framework missing' >&2; exit 1; }
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AntigravityMultiplexer" "$APP/Contents/MacOS/AntigravityMultiplexer"
cp Resources/compatibility.json Resources/create_instance.py Resources/upgrade_all.py Resources/manage_backups.py Resources/destroy_instance.py "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
cp Icon.icns "$APP/Contents/Resources/Icon.icns"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  for COMPONENT in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$FRAMEWORK/Versions/B/$COMPONENT"
  done
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$FRAMEWORK"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$FRAMEWORK"
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
file "$APP/Contents/MacOS/AntigravityMultiplexer"
