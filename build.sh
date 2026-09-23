#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP='Antigravity 多开管理器.app'
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -parse-as-library -target arm64-apple-macos13.0 -framework SwiftUI -framework AppKit Sources/AntigravityMultiplexer.swift -o "$APP/Contents/MacOS/AntigravityMultiplexer"
cp Resources/create_instance.py Resources/upgrade_all.py "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
cp Icon.icns "$APP/Contents/Resources/Icon.icns"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
file "$APP/Contents/MacOS/AntigravityMultiplexer"
