#!/usr/bin/env python3
"""Offline verification of compiled Icon Composer assets. Never launches an app."""
import json
import os
import plistlib
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def verify_app(app, macos=False):
    resources = app / "Contents/Resources" if macos else app
    info = plistlib.loads((app / "Contents/Info.plist" if macos else app / "Info.plist").read_bytes())
    entries = json.loads(subprocess.check_output(["/usr/bin/assetutil", "--info", str(resources / "Assets.car")]))
    names = {entry.get("Name") for entry in entries if entry.get("AssetType") == "IconGroup"}
    assert {"AppIcon/Rising light", "AppIcon/Surface line", "AppIcon/Reflection"} <= names, names
    assert any(entry.get("AssetType") == "IconImageStack" and entry.get("Name") == "AppIcon" for entry in entries)
    if macos:
        assert info["CFBundleIconName"] == "AppIcon"
        assert info["CFBundleIconFile"] == "AppIcon"
        assert (resources / "AppIcon.icns").stat().st_size > 0
    else:
        for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
            icon = info[key]["CFBundlePrimaryIcon"]
            assert icon["CFBundleIconName"] == "AppIcon"
            assert icon["CFBundleIconFiles"]
        assert (resources / "AppIcon60x60@2x.png").stat().st_size > 0
        assert (resources / "AppIcon76x76@2x~ipad.png").stat().st_size > 0
    print(app, "verified three native icon layers, stack, metadata and fallback assets")

def main():
    doc = ROOT / "macOS/AppIcon.icon"
    data = json.loads((doc / "icon.json").read_text())
    layers = [layer for group in data["groups"] for layer in group["layers"]]
    assert len(layers) == 3
    for layer in layers:
        asset = doc / "Assets" / layer["image-name"]
        assert asset.suffix == ".svg" and "<svg" in asset.read_text()
    verify_app(ROOT / "macOS/build/ScreenTimeEditor.app", True)
    verify_app(ROOT / "iOS/build/UNSIGNED-COMPILE-ONLY.app")
    package = ROOT / "iOS/packages/com.kobosh.screentimeeditor_0.1.0_iphoneos-arm64e.deb"
    env = os.environ.copy()
    env["PATH"] = "/opt/homebrew/bin:" + env.get("PATH", "")
    with tempfile.TemporaryDirectory(prefix="ste-icon-package-") as tmp:
        subprocess.run(["dpkg-deb", "-x", str(package), tmp], check=True, env=env)
        verify_app(Path(tmp) / "Applications/ScreenTimeEditor.app")
    print("Editable SVG sources and all three build artifacts passed.")

if __name__ == "__main__":
    main()
