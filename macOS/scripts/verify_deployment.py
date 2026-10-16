#!/usr/bin/env python3
"""Fail closed on incorrect platform/minimum OS in compiled validation artifacts."""
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def binary(path, platform, minimum):
    output = subprocess.check_output(
        ["xcrun", "vtool", "-show-build", str(path)], text=True)
    actual_platforms = re.findall(r"^\s*platform\s+(\S+)", output, re.M)
    actual_minima = re.findall(r"^\s*minos\s+(\S+)", output, re.M)
    if not actual_platforms or len(actual_platforms) != len(actual_minima):
        raise ValueError(f"Missing LC_BUILD_VERSION in {path}")
    if any(p != platform for p in actual_platforms):
        raise ValueError(f"Wrong platform in {path}: {actual_platforms}")
    def version(v):
        parts = tuple(map(int, v.split(".")))
        return parts + (0,) * (3 - len(parts))
    if any(version(v) != version(minimum) for v in actual_minima):
        raise ValueError(f"Wrong minimum OS in {path}: {actual_minima}")
    return {"path": str(path.relative_to(ROOT)), "platform": platform,
            "minos": minimum, "architecturesChecked": len(actual_minima)}

def verify(target):
    if target == "macos":
        app = ROOT / "macOS/build/ScreenTimeEditor.app"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if info.get("LSMinimumSystemVersion") != "26.0":
            raise ValueError("Mac plist minimum must be 26.0")
        return [binary(app / "Contents/MacOS/ScreenTimeEditor", "MACOS", "26.0")]
    if target == "ios":
        app = ROOT / "iOS/build/UNSIGNED-COMPILE-ONLY.app"
        info = plistlib.loads((app / "Info.plist").read_bytes())
        if info.get("MinimumOSVersion") != "18.0":
            raise ValueError("iOS plist minimum must be 18.0")
        return [binary(app / name, "IOS", "18.0")
                for name in ("ScreenTimeEditor", "stehelper")]
    raise ValueError(f"Unknown target {target}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("Specify macos and/or ios")
    print(json.dumps([item for target in sys.argv[1:]
                      for item in verify(target)], indent=2))
