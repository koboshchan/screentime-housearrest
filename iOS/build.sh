#!/bin/bash
# Local compiler validation only. Does not sign, package, install, or run on iOS.
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
T=arm64-apple-ios18.0
HOSTSDK=$(xcrun --sdk macosx --show-sdk-path)
HOST_TARGET=arm64-apple-macos26.0
OUT=build
# Preserve all existing artifacts; replace only named compiler-validation outputs.
mkdir -p "$OUT/UNSIGNED-COMPILE-ONLY.app"
APP="$OUT/UNSIGNED-COMPILE-ONLY.app"
xcrun --sdk iphoneos swiftc -sdk "$SDK" -target "$T" -O -parse-as-library -o "$APP/ScreenTimeEditor" Core/*.swift App/*.swift -framework CryptoKit -lsqlite3 -lz
# Production compile uses real C authentication, never host fixture defines.
xcrun --sdk iphoneos clang -isysroot "$SDK" -target "$T" -c Helper/Auth.c -o "$OUT/Auth-production.o"
xcrun --sdk iphoneos swiftc -sdk "$SDK" -target "$T" -O -D STE_CALLER_AUTH -o "$APP/stehelper" Core/*.swift Helper/main.swift "$OUT/Auth-production.o" -framework CryptoKit -lsqlite3 -lz
cp App/Info.plist "$APP/Info.plist"
bash ../macOS/scripts/compile-icon.sh iphoneos "$APP" "$APP/Info.plist"
xcrun --sdk macosx swiftc -sdk "$HOSTSDK" -target "$HOST_TARGET" -O -o "$OUT/tests" Core/Model.swift Tests/main.swift
"$OUT/tests"
# Host denial helper has no auth define, so exits before any storage access.
xcrun --sdk macosx swiftc -sdk "$HOSTSDK" -target "$HOST_TARGET" -O -o "$OUT/helper-host-stub" Core/*.swift Helper/main.swift -framework CryptoKit -lsqlite3 -lz
xcrun --sdk macosx swiftc -sdk "$HOSTSDK" -target "$HOST_TARGET" -D HOST_IPC_TEST -parse-as-library Core/*.swift App/HelperClient.swift Tests/IPCChecks.swift -framework CryptoKit -lsqlite3 -lz -o "$OUT/ipc-checks"
"$OUT/ipc-checks" "$PWD/$OUT/helper-host-stub"
python3 Tests/check_scaffold.py
# Exercise the production C sanitizer with a real Darwin environ vector.
xcrun --sdk macosx clang -isysroot "$HOSTSDK" -target "$HOST_TARGET" Tests/AuthEnvironmentChecks.c -o "$OUT/auth-environment-checks"
"$OUT/auth-environment-checks"
# Fixture constructor exists ONLY in this standalone host test executable.
xcrun --sdk macosx swiftc -sdk "$HOSTSDK" -target "$HOST_TARGET" -O -D HOST_STORAGE_TEST -parse-as-library Core/*.swift Tests/NativeStorageChecks.swift -framework CryptoKit -lsqlite3 -lz -o "$OUT/native-storage-checks"
"$OUT/native-storage-checks"
xcrun --sdk macosx swiftc -sdk "$HOSTSDK" -target "$HOST_TARGET" -O -D HOST_STORAGE_TEST -parse-as-library Core/*.swift Tests/GeminiRouteChecks.swift -framework CryptoKit -lsqlite3 -lz -o "$OUT/gemini-route-checks"
"$OUT/gemini-route-checks"
# Positive and corruption checks on already signed artifacts, if available.
# This does not rebuild, alter, install or run any package.
if [[ -f .theos/_/Applications/ScreenTimeEditor.app/ScreenTimeEditor ]]; then
    python3 Tests/package_checks.py .theos/_/Applications/ScreenTimeEditor.app/ScreenTimeEditor
    python3 Tests/package_checks.py .theos/_/Applications/ScreenTimeEditor.app/stehelper
fi
file "$APP/ScreenTimeEditor" "$APP/stehelper"
python3 ../macOS/scripts/verify_deployment.py ios
printf '%s\n' 'COMPILE VALIDATION ONLY. Unsigned, not installable, live reads/backups/writes disabled.' > "$OUT/NOT-INSTALLABLE.txt"
