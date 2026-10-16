#!/usr/bin/env python3
"""Offline negative checks using a copy of a generated Mach-O, no device I/O."""
import contextlib
import io
import struct
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_package import signature

source = Path(sys.argv[1]).read_bytes()
def check(data, accepted):
    with tempfile.TemporaryDirectory(prefix="ste-signature-test-") as tmp:
        path = Path(tmp)/"binary"
        path.write_bytes(data)
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                signature(path)
        except (AssertionError, KeyError, ValueError, struct.error):
            assert not accepted, "Valid signature rejected"
        else:
            assert accepted, "Corrupt signature accepted"

check(source, True)
changed = bytearray(source); changed[4096] ^= 1
check(changed, False)
changed = bytearray(source); changed[4:8] = struct.pack("<I", 7)
check(changed, False)
changed = bytearray(source)
offset = changed.find(b"platform-application")
assert offset > 0
changed[offset] ^= 1
check(changed, False)
check(source[:32], False)
print("5 signature checks passed, valid plus code/architecture/entitlements/truncation rejection")
