#!/bin/bash
# Local compiler validation only. Does not sign, package, install, or run on iOS.
set -euo pipefail
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
T=arm64-apple-ios15.0
HOSTSDK=$(xcrun --sdk macosx --show-sdk-path)
OUT=build
# Only this task's generated validation directory is rebuilt.
rm -rf "$OUT"
mkdir -p "$OUT/UNSIGNED-COMPILE-ONLY.app"
APP="$OUT/UNSIGNED-COMPILE-ONLY.app"
xcrun --sdk iphoneos swiftc -sdk "$SDK" -target "$T" -O -parse-as-library -o "$APP/ScreenTimeEditor" Core/*.swift App/*.swift
xcrun --sdk iphoneos swiftc -sdk "$SDK" -target "$T" -O -o "$APP/stehelper" Core/Model.swift Helper/main.swift
cp App/Info.plist "$APP/Info.plist"
xcrun --sdk macosx swiftc -sdk "$HOSTSDK" -O -o "$OUT/tests" Core/Model.swift Tests/main.swift
"$OUT/tests"
# This helper is a new no-I/O stub, not any legacy injector.
xcrun --sdk macosx swiftc -sdk "$HOSTSDK" -O -o "$OUT/helper-host-stub" Core/Model.swift Helper/main.swift
xcrun --sdk macosx swiftc -sdk "$HOSTSDK" -D HOST_IPC_TEST -parse-as-library Core/Model.swift App/HelperClient.swift Tests/IPCChecks.swift -o "$OUT/ipc-checks"
"$OUT/ipc-checks" "$PWD/$OUT/helper-host-stub"
python3 Tests/check_scaffold.py
file "$APP/ScreenTimeEditor" "$APP/stehelper"
printf '%s\n' 'COMPILE VALIDATION ONLY. Unsigned, not installable, live reads/backups/writes disabled.' > "$OUT/NOT-INSTALLABLE.txt"
