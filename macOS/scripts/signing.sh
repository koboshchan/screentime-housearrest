#!/bin/bash
# Persistent local certificate, never ad-hoc signing or automatic regeneration.
set -euo pipefail
DIR="$HOME/Library/Application Support/ScreenTimeEditor/Signing"
LOCAL_IDENTITY=5BAC8837B31A6449CA39EFA3CB494F24AD366428
IDENTITY="${SIGN_IDENTITY:-$LOCAL_IDENTITY}"
if [[ ! "$IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  echo "SIGN_IDENTITY must be a persistent certificate SHA-1 fingerprint; ad-hoc signing is refused." >&2
  exit 2
fi
IDENTITY=$(printf '%s' "$IDENTITY" | tr '[:lower:]' '[:upper:]')
KEYCHAIN_ARGS=()
if [[ "$IDENTITY" == "$LOCAL_IDENTITY" ]]; then
  # This keychain contains only this app's local certificate. Never unlock or
  # change access controls on the user's login keychain.
  [[ -f "$DIR/keychain-password" && ! -L "$DIR/keychain-password" ]] || exit 2
  KEYCHAIN_ARGS=(--keychain "$DIR/local-signing.keychain-db")
  security unlock-keychain -p "$(cat "$DIR/keychain-password")" "$DIR/local-signing.keychain-db"
  # Locally self-signed, deliberately not installed as a system/user trust root.
  # codesign verification and certificate-anchored DR checks verify the app.
  IDENTITIES=$(security find-identity -p codesigning "$DIR/local-signing.keychain-db")
  printf '%s\n' "$IDENTITIES" | awk -v hash="$IDENTITY" '
    $2 == hash && ($0 !~ /CSSMERR_/ || $0 ~ /CSSMERR_TP_NOT_TRUSTED/) { found=1 }
    END { exit !found }'
else
  security find-identity -v -p codesigning | awk -v hash="$IDENTITY" '
    $2 == hash && $0 !~ /CSSMERR_|errSec/ { found=1 }
    END { exit !found }'
fi
case "${1:-}" in
  --check) printf '%s\n' "$IDENTITY" ;;
  --sign)
    [[ $# == 2 ]] || exit 2
    codesign --force --options runtime "${KEYCHAIN_ARGS[@]}" --sign "$IDENTITY" "$2"
    codesign --verify --strict "$2"
    ;;
  *) echo "Use --check or --sign APP." >&2; exit 2 ;;
esac
