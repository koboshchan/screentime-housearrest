#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash scripts/signing.sh --check >/dev/null
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=build/ScreenTimeEditor.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ScreenTimeEditor" "$APP/Contents/MacOS/"
# Immutable embedded backend, isolated interpreter, no writable root script.
python3 scripts/build_admin_helper.py
xcrun swiftc -O -target arm64-apple-macos26.0 .build/admin-helper/main.swift -o "$APP/Contents/MacOS/ScreenTimeAdminHelper"
bash scripts/signing.sh --sign "$APP/Contents/MacOS/ScreenTimeAdminHelper"
cp -R "$BIN/ScreenTimeEditor_ScreenTimeEditor.bundle" "$APP/Contents/Resources/" 2>/dev/null || cp -R "$BIN"/*.bundle "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Surface</string>
<key>CFBundleDisplayName</key><string>Surface</string>
<key>CFBundleIdentifier</key><string>app.screentimeeditor.macos</string>
<key>CFBundleExecutable</key><string>ScreenTimeEditor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
bash scripts/compile-icon.sh macosx "$APP/Contents/Resources" "$APP/Contents/Info.plist"
# Reuse the pinned keychain identity; never silently replace it with ad-hoc signing.
bash scripts/signing.sh --sign "$APP"
python3 scripts/verify_deployment.py macos
echo built "$APP"
