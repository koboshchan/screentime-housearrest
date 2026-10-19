#!/usr/bin/env python3
"""Offline archive, deployment and ldid CodeDirectory verification. Never installs."""
import hashlib
import io
import plistlib
import struct
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
KEYS = ("platform-application", "com.apple.private.security.no-sandbox",
        "com.apple.private.security.storage.AppBundles",
        "com.apple.private.security.storage.AppDataContainers",
        "com.apple.private.security.storage-exempt.heritable")

def command(*args):
    return subprocess.check_output(args)

def signature(path):
    data = path.read_bytes()
    assert data[:4] == b"\xcf\xfa\xed\xfe", "Expected thin arm64 Mach-O"
    assert struct.unpack_from("<I", data, 4)[0] == 0x100000c, "Wrong architecture"
    pos = 32
    sig = None
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        cmd, size = struct.unpack_from("<II", data, pos)
        assert size >= 8 and pos + size <= len(data)
        if cmd == 0x1d:
            offset, length = struct.unpack_from("<II", data, pos + 8)
            sig = data[offset:offset+length]
        pos += size
    assert sig is not None, "Missing LC_CODE_SIGNATURE"
    magic, size, count = struct.unpack_from(">III", sig)
    assert magic == 0xfade0cc0 and size <= len(sig)
    blobs = {}
    for index in range(count):
        slot, off = struct.unpack_from(">II", sig, 12+index*8)
        _, length = struct.unpack_from(">II", sig, off)
        blobs[slot] = sig[off:off+length]
    cd = blobs[0]
    assert struct.unpack_from(">I", cd)[0] == 0xfade0c02
    hash_offset, _, specials, pages, limit = struct.unpack_from(">IIIII", cd, 16)
    hash_size, hash_type, _, page_exp = struct.unpack_from("BBBB", cd, 36)
    assert hash_type == 2 and hash_size == 32, "Expected SHA256 CodeDirectory"
    assert pages == (limit + (1 << page_exp) - 1) >> page_exp
    for page in range(pages):
        block = data[page*(1<<page_exp):min((page+1)*(1<<page_exp), limit)]
        assert hashlib.sha256(block).digest() == cd[hash_offset+page*hash_size:hash_offset+(page+1)*hash_size], "Code page hash mismatch"
    ent = blobs[5]
    assert specials >= 5
    assert hashlib.sha256(ent).digest() == cd[hash_offset-5*hash_size:hash_offset-4*hash_size], "Entitlement hash mismatch"
    parsed = plistlib.loads(ent[8:])
    assert all(parsed.get(key) is True for key in KEYS)
    assert plistlib.loads(command("ldid", "-e", str(path))) == parsed
    if path.name == "stehelper":
        assert parsed.get("com.apple.rootless.storage.coreduet_knowledge_store") is True
    build = command("xcrun", "vtool", "-show-build", str(path)).decode()
    assert "platform IOS" in build and "minos 18.0" in build, build
    print(path.name, "arm64 iOS18 SHA256 CodeDirectory pages and entitlements verified")

def verify(package, *, scheme="roothide"):
    assert scheme in ("roothide", "rootless")
    prefix = "var/jb/" if scheme == "rootless" else ""
    arch = "iphoneos-arm64" if scheme == "rootless" else "iphoneos-arm64e"
    fields = command("dpkg-deb", "-f", str(package)).decode()
    assert "Package: com.kobosh.surface\n" in fields
    assert "Architecture: " + arch + "\n" in fields
    assert "firmware (>= 18.0)" in fields
    raw = command("dpkg-deb", "--fsys-tarfile", str(package))
    with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
        for entry in archive:
            assert "ScreenTimeEditor.app" not in Path(entry.name).parts, "Old app path must remain untouched"
            assert entry.uid == 0 and entry.gid == 0, "Non-root archive ownership"
            helper = entry.name.removeprefix("./") == prefix + "Applications/Surface.app/stehelper"
            assert entry.mode & 0o7777 == 0o4755 if helper else not (entry.mode & 0o6000), "Unexpected privileged mode"
            assert not (entry.mode & 0o022), "Writable package entry"
            assert not entry.issym() and not entry.islnk(), "Unexpected package link"
            assert ".." not in Path(entry.name).parts and not entry.name.startswith("/")
    with tempfile.TemporaryDirectory(prefix="ste-package-verify-") as tmp:
        command("dpkg-deb", "-x", str(package), tmp)
        command("dpkg-deb", "-e", str(package), tmp + "/control")
        assert not any((Path(tmp)/"control"/name).exists() for name in ("preinst","postinst","prerm","postrm")), "Unexpected maintainer script"
        app = Path(tmp)/prefix/"Applications/Surface.app"
        info = plistlib.loads((app/"Info.plist").read_bytes())
        assert info["MinimumOSVersion"] == "18.0"
        assert info["CFBundleIdentifier"] == "com.kobosh.surface"
        for name in ("ScreenTimeEditor", "stehelper"):
            assert (app/name).stat().st_mode & 0o7777 == (0o4755 if name == "stehelper" else 0o755)
            signature(app/name)
        app_hash = next(line.split("=",1)[1] for line in command("ldid","-h",str(app/"ScreenTimeEditor")).decode().splitlines() if line.startswith("CDHash="))
        assert app_hash.encode() in (app/"stehelper").read_bytes(), "Helper caller pin does not match packaged app"
    print("SHA256", hashlib.sha256(package.read_bytes()).hexdigest())
    print("Offline package validation only. Privilege and device runtime not verified.")

if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve(), scheme=sys.argv[2] if len(sys.argv) > 2 else "roothide")
