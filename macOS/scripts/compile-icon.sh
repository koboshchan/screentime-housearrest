#!/bin/bash
# Compile the editable Icon Composer document with Apple's asset compiler.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLATFORM="${1:?macosx or iphoneos}"
OUT="${2:?resource output directory}"
INFO="${3:-}"
case "$PLATFORM" in
  macosx) MIN=26.0 ;;
  iphoneos) MIN=18.0 ;;
  *) echo "Unsupported icon platform: $PLATFORM" >&2; exit 2 ;;
esac
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ste-icon.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"
ARGS=("$ROOT/macOS/AppIcon.icon" --compile "$TMP" --platform "$PLATFORM"
      --minimum-deployment-target "$MIN" --app-icon AppIcon
      --output-partial-info-plist "$TMP/partial.plist" --output-format human-readable-text)
if [[ "$PLATFORM" == iphoneos ]]; then
  ARGS+=(--target-device iphone --target-device ipad)
fi
xcrun actool "${ARGS[@]}"
python3 - "$TMP" "$OUT" "$INFO" <<'PY'
import pathlib, plistlib, shutil, sys
source, output = map(pathlib.Path, sys.argv[1:3])
partial = plistlib.loads((source / "partial.plist").read_bytes())
assert partial, "Asset compiler emitted no icon metadata"
assert (source / "Assets.car").is_file(), "Missing compiled icon"
for path in source.iterdir():
    if path.name == "Assets.car" or path.suffix in (".png", ".icns"):
        shutil.copy2(path, output / path.name)
if sys.argv[3]:
    info = pathlib.Path(sys.argv[3])
    data = plistlib.loads(info.read_bytes())
    data.update(partial)
    info.write_bytes(plistlib.dumps(data, sort_keys=False))
PY
