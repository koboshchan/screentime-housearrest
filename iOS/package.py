#!/usr/bin/env python3
"""Build and verify a RootHide package locally. Does not install or run on iOS."""
import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path
from verify_package import verify

ROOT = Path(__file__).resolve().parent

def sources():
    paths = sorted(p for folder in ("Core", "App", "Helper") for p in (ROOT/folder).glob("*") if p.is_file())
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}

def main():
    os.chdir(ROOT)
    env = os.environ.copy()
    env["PATH"] = "/opt/homebrew/bin:" + env.get("PATH", "")
    for tool in ("gmake", "ldid", "dpkg-deb", "xcrun"):
        if not shutil.which(tool, path=env["PATH"]):
            raise RuntimeError("Missing tool: " + tool)
    theos = Path(env.get("STE_THEOS", str(Path.home()/"theos-roothide")))
    if not (theos/"vendor/mod/roothide").is_dir():
        raise RuntimeError("Official RootHide Theos fork required at " + str(theos))
    before = sources()
    subprocess.run(["gmake", "ScreenTimeEditor", "THEOS=" + str(theos)], check=True, env=env)
    app = ROOT/".theos/obj/ScreenTimeEditor.app/ScreenTimeEditor"
    signed = subprocess.check_output(["ldid", "-h", str(app)], env=env).decode()
    pin = next(line.split("=", 1)[1] for line in signed.splitlines() if line.startswith("CDHash="))
    if len(pin) != 40 or any(c not in "0123456789abcdef" for c in pin):
        raise RuntimeError("Invalid app CDHash")
    subprocess.run(["gmake", "package", "THEOS=" + str(theos), "STE_APP_CDHASH=" + pin], check=True, env=env)
    if sources() != before:
        raise RuntimeError("Sources changed while building. Wait for source owner handoff and rebuild.")
    os.environ["PATH"] = env["PATH"]
    package = ROOT/"packages/com.kobosh.screentimeeditor_0.1.0_iphoneos-arm64e.deb"
    verify(package)
    print(package)
    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AssertionError, RuntimeError, subprocess.CalledProcessError) as error:
        print("PACKAGE VALIDATION FAILED:", error, file=sys.stderr)
        sys.exit(2)
