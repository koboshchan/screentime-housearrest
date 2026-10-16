#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=build/ScreenTimeEditor.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ScreenTimeEditor" "$APP/Contents/MacOS/"
cp -R "$BIN/ScreenTimeEditor_ScreenTimeEditor.bundle" "$APP/Contents/Resources/" 2>/dev/null || cp -R "$BIN"/*.bundle "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Screen Time Editor</string>
<key>CFBundleIdentifier</key><string>app.screentimeeditor.macos</string>
<key>CFBundleExecutable</key><string>ScreenTimeEditor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
# Ad-hoc signing by default; set SIGN_IDENTITY to a Developer ID name to sign for distribution.
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo built "$APP"
