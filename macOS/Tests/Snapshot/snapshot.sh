#!/bin/bash
# Offscreen ImageRenderer of the real UI with the real backend result. Not shipped, not a display screenshot.
set -euo pipefail
cd "$(dirname "$0")/../.."
O=build/snap-obj; mkdir -p build/snapshots $O
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun swiftc -sdk "$SDK" -target arm64-apple-macos26.0 -swift-version 6 -parse-as-library -emit-library -emit-module \
  -module-name STCore Sources/STCore/*.swift -o $O/libSTCore.dylib -emit-module-path $O/STCore.swiftmodule
xcrun swiftc -sdk "$SDK" -target arm64-apple-macos26.0 -swift-version 6 -parse-as-library -I $O -L $O -lSTCore \
  -Xlinker -rpath -Xlinker "@executable_path" \
  Sources/ScreenTimeEditor/{ContentView,EditorModel,SessionList,TimelineEditor}.swift Tests/Snapshot/main.swift -o $O/snapshot
$O/snapshot Sources/ScreenTimeEditor/Resources/backend.py build/snapshots
