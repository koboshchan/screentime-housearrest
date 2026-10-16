#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/snapshots
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun swiftc -sdk "$SDK" -target arm64-apple-macos26.0 -parse-as-library Core/Model.swift App/AccessStatusView.swift Tests/StatusSnapshot.swift -o build/status-snapshot
build/status-snapshot build/snapshots
