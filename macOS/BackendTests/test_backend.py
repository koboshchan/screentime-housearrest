import importlib.util
import json
import math
from pathlib import Path
import sqlite3
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

spec = importlib.util.spec_from_file_location("backend", Path(__file__).resolve().parents[1] / "Sources/ScreenTimeEditor/Resources/backend.py")
if not spec.origin or not Path(spec.origin).exists():
    spec = importlib.util.spec_from_file_location("backend", Path(__file__).with_name("backend.py"))
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)

def vi(number):
    result = bytearray()
    while number >= 128:
        result.append((number & 127) | 128)
        number >>= 7
    result.append(number)
    return bytes(result)

def payload(starting, timestamp, bundle="com.test.App"):
    raw = bundle.encode()
    return b"\x08" + vi(int(starting)) + b"\x11" + struct.pack("<d", timestamp+b.COCOA_OFFSET) + b"\x1a" + vi(len(raw)) + raw

def segment(events, size=4096):
    data = bytearray(size)
    struct.pack_into("<4sIdIIQ", data, 0, b"SEGB", len(events), 100., 10, 0xffffffff, 0)
    end = 0
    for index, (starting, timestamp, bundle) in enumerate(events):
        raw = payload(starting, timestamp, bundle)
        aligned = (end + 3) & ~3
        end = aligned + 8 + len(raw)
        if 32 + end > size - 16 * len(events):
            raise ValueError("Fixture overflow")
        struct.pack_into("<II", data, 32+aligned, zlib.crc32(raw), 0)
        data[40+aligned:32+end] = raw
        struct.pack_into("<IId", data, size-16*(index+1), end, 1, timestamp)
    return bytes(data)

class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=str(Path(tempfile.gettempdir()).resolve()))
        self.addCleanup(self.tmp.cleanup)
        self.engine = b.Engine(self.tmp.name)
        self.engine.stream.mkdir(parents=True)
        self.engine.database.parent.mkdir(parents=True)
        with sqlite3.connect(self.engine.database) as c:
            c.execute("CREATE TABLE ZOBJECT (ZSTREAMNAME TEXT,ZSTARTDATE REAL,ZENDDATE REAL,ZVALUESTRING TEXT)")
            c.execute("INSERT INTO ZOBJECT VALUES ('/app/usage',100,200,'com.test.App')")
            c.execute("INSERT INTO ZOBJECT VALUES ('/other',100,200,'keep')")
        (self.engine.stream / "a").write_bytes(segment([(True,100,"com.test.App")]))
        (self.engine.stream / "b").write_bytes(segment([(False,200,"com.test.App")]))

    def request(self):
        return dict(revision=self.engine.read()["revision"],dayStart=0,dayEnd=86400,
                    sessions=[dict(id="one",bundle="com.test.App",start=100,end=200)])

    def test_cross_segment_pairing(self):
        read = self.engine.read()
        self.assertEqual([(x["start"],x["end"]) for x in read["sessions"]],[(100,200)])
        self.assertFalse(read["canApply"])

    def test_crc(self):
        path = self.engine.stream / "a"
        data = bytearray(path.read_bytes()); data[44] ^= 1; path.write_bytes(data)
        with self.assertRaisesRegex(b.StorageError, "CRC"): self.engine.read()

    def test_footer_collision(self):
        data = bytearray(segment([(True,100,"a")]))
        struct.pack_into("<I",data,len(data)-16,len(data))
        with self.assertRaisesRegex(b.StorageError, "overlap"): b.parse_segment(data)

    def test_huge_count(self):
        data = bytearray(segment([]))
        struct.pack_into("<I",data,4,0xffffffff)
        with self.assertRaises(b.StorageError): b.parse_segment(data)

    def test_version(self):
        data = bytearray(segment([])); struct.pack_into("<I",data,16,11)
        with self.assertRaises(b.StorageError): b.parse_segment(data)

    def test_protobuf_long_bundle(self):
        bundle = "com."+"x"*300
        self.assertEqual(b.decode_usage(payload(True,100,bundle)),(True,100,bundle))

    def test_protobuf_unknown_fields(self):
        raw = payload(True,100)+b"\x20"+vi(500)+b"\x35abcd"+b"\x39abcdefgh"
        self.assertEqual(b.decode_usage(raw)[1],100)

    def test_protobuf_truncation_and_overflow(self):
        for raw in (b"\x80",b"\x80"*11,b"\x1a\xff\x01abc",b"\x11a",b"\x00"):
            with self.subTest(raw=raw):
                with self.assertRaises(b.StorageError): b.protobuf(raw)

    def test_duplicate_field(self):
        with self.assertRaises(b.StorageError): b.decode_usage(payload(True,100)+b"\x08\x01")

    def test_unpaired_end(self):
        (self.engine.stream / "a").unlink()
        with self.assertRaisesRegex(b.StorageError,"Unmatched"): self.engine.read()

    def test_unclosed_start_warning(self):
        (self.engine.stream / "b").unlink()
        result = self.engine.read()
        self.assertEqual(result["sessions"],[])
        self.assertTrue(any("Unclosed" in w for w in result["warnings"]))

    def test_duplicate_start(self):
        (self.engine.stream / "b").write_bytes(segment([(True,150,"com.test.App")]))
        with self.assertRaises(b.StorageError): self.engine.read()

    def test_missing_db_honest(self):
        self.engine.database.unlink()
        with self.assertRaisesRegex(b.StorageError,"missing"): self.engine.read()

    def test_schema_honest(self):
        with sqlite3.connect(self.engine.database) as c: c.execute("DROP TABLE ZOBJECT")
        with self.assertRaisesRegex(b.StorageError,"schema"): self.engine.read()

    def test_stale_revision(self):
        request = self.request()
        with sqlite3.connect(self.engine.database) as c: c.execute("INSERT INTO ZOBJECT VALUES ('/other',200,300,'keep')")
        with self.assertRaisesRegex(b.StorageError,"changed since"): self.engine.apply(request)

    def test_apply_never_mutates(self):
        request = self.request()
        before = self.engine.fingerprint()
        with self.assertRaisesRegex(b.StorageError,"Apply blocked"): self.engine.apply(request)
        self.assertEqual(before,self.engine.fingerprint())

    def test_validation(self):
        for field,value in (("dayStart",math.nan),("dayEnd",math.inf),("revision","bad"),("sessions",{})):
            req = self.request(); req[field] = value
            with self.subTest(field=field):
                with self.assertRaises(b.StorageError): b.validate_edit(req)

    def test_cross_day_requires_clip(self):
        req = self.request(); req["sessions"][0]["end"] = 90000
        with self.assertRaisesRegex(b.StorageError,"clipped"): b.validate_edit(req)

    def test_preserve_both_outside_pieces(self):
        old = [dict(id="a",bundle="x",start=-10,end=100)]
        self.assertEqual([(s["start"],s["end"]) for s in b.preserve_outside(old,0,50)],[(-10,0),(50,100)])
        self.assertEqual(old[0]["end"],100)

    def test_symlink_refused(self):
        path = self.engine.stream / "a"
        original = self.engine.stream / ".original"
        path.rename(original); path.symlink_to(original)
        with self.assertRaises(b.StorageError): self.engine.read()

    def test_backup_verified_and_sealed(self):
        destination = Path(self.tmp.name) / "backup"
        manifest = b.verified_backup(self.engine,destination)
        self.addCleanup(lambda: destination.chmod(0o700))
        self.assertEqual(destination.stat().st_mode & 0o777,0o500)
        self.assertEqual(len(manifest["files"]),3)
        with sqlite3.connect("file:"+str(destination / "knowledgeC.db")+"?mode=ro",uri=True) as c:
            self.assertEqual(c.execute("SELECT COUNT(*) FROM ZOBJECT").fetchone()[0],2)
        self.assertTrue(all(p.stat().st_mode & 0o777 == 0o400 for p in destination.iterdir()))

    def test_wal_backup(self):
        c = sqlite3.connect(self.engine.database)
        self.addCleanup(c.close)
        c.execute("PRAGMA journal_mode=WAL")
        c.execute("INSERT INTO ZOBJECT VALUES ('/other',400,500,'wal')")
        c.commit()
        dest = Path(self.tmp.name) / "backupwal"
        b.verified_backup(self.engine,dest)
        self.addCleanup(lambda: dest.chmod(0o700))
        with sqlite3.connect("file:"+str(dest / "knowledgeC.db")+"?mode=ro",uri=True) as copy:
            self.assertEqual(copy.execute("SELECT COUNT(*) FROM ZOBJECT").fetchone()[0],3)

    def test_backup_existing_refused(self):
        with self.assertRaises(b.StorageError): b.verified_backup(self.engine,Path(self.tmp.name))

    def test_concurrent_read(self):
        original = self.engine.fingerprint
        calls = 0
        def changed():
            nonlocal calls
            calls += 1
            return original() if calls == 1 else "f"*64
        self.engine.fingerprint = changed
        with self.assertRaisesRegex(b.StorageError,"Sources changed"): self.engine.read()

    def test_status_unknown_not_assumed(self):
        def runner(*args,**kwargs): raise OSError("not available")
        self.assertEqual(b.status(runner)["sip"],"unknown")
        self.assertEqual(b.status(runner)["macOS"],"unknown")
        self.assertEqual(b.status(runner)["build"],"unknown")

    def test_status_real_output_parsing(self):
        def runner(args,**kwargs):
            text = "System Integrity Protection status: enabled." if args[-1]=="status" else "27.0"
            return subprocess.CompletedProcess(args,0,text,"")
        self.assertEqual(b.status(runner)["sip"],"enabled")

    def test_cli_invalid_json(self):
        p = subprocess.run([sys.executable,b.__file__],input='{"command":"read","x":NaN}',text=True,capture_output=True)
        self.assertEqual(p.returncode,1)
        self.assertIn("error",json.loads(p.stdout))


    def snapshot(self):
        dest = Path(self.tmp.name) / "sealed"
        b.verified_backup(self.engine, dest)
        self.addCleanup(lambda: dest.chmod(0o700))
        return dest

    def unseal_file(self, dest, name, data):
        dest.chmod(0o700)
        path = dest / name
        path.chmod(0o600)
        path.write_bytes(data)
        path.chmod(0o400)
        dest.chmod(0o500)

    def test_independent_verify(self):
        dest = self.snapshot()
        self.assertEqual(b.verify_backup(dest)["revision"], self.engine.fingerprint())

    def test_verify_wrong_revision(self):
        dest = self.snapshot()
        with self.assertRaises(b.StorageError): b.verify_backup(dest, "0"*64)

    def test_verify_corruption(self):
        dest = self.snapshot()
        self.unseal_file(dest, "segment-0", b"corrupt")
        with self.assertRaisesRegex(b.StorageError, "digest"): b.verify_backup(dest)

    def test_verify_missing_complete(self):
        dest = self.snapshot(); dest.chmod(0o700)
        (dest/"COMPLETE").unlink(); dest.chmod(0o500)
        with self.assertRaisesRegex(b.StorageError, "incomplete"): b.verify_backup(dest)

    def test_verify_invalid_marker(self):
        dest = self.snapshot(); dest.chmod(0o700)
        b.private_file(dest/"INVALID", b"failed"); (dest/"INVALID").chmod(0o400)
        dest.chmod(0o500)
        with self.assertRaisesRegex(b.StorageError, "invalid"): b.verify_backup(dest)

    def test_verify_extra_file(self):
        dest = self.snapshot(); dest.chmod(0o700)
        b.private_file(dest/"extra", b"extra"); (dest/"extra").chmod(0o400)
        dest.chmod(0o500)
        with self.assertRaisesRegex(b.StorageError, "inventory"): b.verify_backup(dest)

    def test_verify_permissions(self):
        dest = self.snapshot()
        (dest/"segment-0").chmod(0o644)
        with self.assertRaisesRegex(b.StorageError, "private"): b.verify_backup(dest)

    def test_verify_symlink_entry(self):
        dest = self.snapshot(); dest.chmod(0o700)
        (dest/"segment-0").unlink(); (dest/"segment-0").symlink_to(dest/"segment-1")
        dest.chmod(0o500)
        with self.assertRaises(b.StorageError): b.verify_backup(dest)

    def test_verify_symlink_parent(self):
        dest = self.snapshot()
        alias = Path(self.tmp.name)/"alias"; alias.symlink_to(dest, target_is_directory=True)
        with self.assertRaisesRegex(b.StorageError, "Symlink"): b.verify_backup(alias)

    def test_checked_bytes_symlink_parent(self):
        alias = Path(self.tmp.name)/"alias"
        alias.symlink_to(self.engine.stream, target_is_directory=True)
        with self.assertRaisesRegex(b.StorageError, "Symlink"): b.checked_bytes(alias/"a")

    def test_backup_failure_invalid(self):
        original = self.engine.open_database
        def fail(): raise b.StorageError("injected failure")
        self.engine.open_database = fail
        dest = Path(self.tmp.name)/"failed"
        with self.assertRaisesRegex(b.StorageError, "injected"): b.verified_backup(self.engine, dest)
        self.assertTrue((dest/"INVALID").is_file())
        self.assertEqual((dest/"knowledgeC.db").stat().st_mode & 0o777, 0o600)
        with self.assertRaises(b.StorageError): b.verify_backup(dest)
        self.engine.open_database = original

    def test_backup_source_change_invalid(self):
        original = self.engine.fingerprint
        calls = [0]
        def change():
            calls[0] += 1
            return original() if calls[0] == 1 else "f"*64
        self.engine.fingerprint = change
        dest = Path(self.tmp.name)/"changed"
        with self.assertRaisesRegex(b.StorageError, "changed"): b.verified_backup(self.engine, dest)
        self.assertTrue((dest/"INVALID").is_file())

    def test_backup_symlink_destination_parent(self):
        alias = Path(self.tmp.name)/"alias"; alias.symlink_to(self.tmp.name, target_is_directory=True)
        with self.assertRaisesRegex(b.StorageError, "Symlink"):
            b.verified_backup(self.engine, alias/"backup")

    def test_verify_manifest_schema_and_paths(self):
        dest = self.snapshot()
        manifest = b.verify_backup(dest)
        manifest["files"]["../escape"] = manifest["files"].pop("segment-0")
        raw = json.dumps(manifest).encode()
        self.unseal_file(dest, "manifest.json", raw)
        self.unseal_file(dest, "COMPLETE", b.hashlib.sha256(raw).hexdigest().encode())
        with self.assertRaises(b.StorageError): b.verify_backup(dest)

    def test_status_capability_contract(self):
        def runner(*a, **k): raise OSError("fixture")
        value = b.status(runner)
        self.assertFalse(value["canApply"])
        self.assertEqual(value["supportedWriters"], [])
        self.assertTrue(value["applyBlockReason"])
        self.assertEqual(self.engine.read()["applyBlockReason"], value["applyBlockReason"])

    def test_permission_denied_distinct(self):
        from unittest.mock import patch
        with patch.object(b, "no_symlink_parents", side_effect=PermissionError("fixture denied")):
            with self.assertRaises(b.StorageError) as caught: self.engine.source_paths()
            self.assertEqual(caught.exception.code, "permission_denied")

    def test_database_integrity_rechecked(self):
        dest = self.snapshot()
        manifest = b.verify_backup(dest)
        data = b"not a sqlite database"
        self.unseal_file(dest, "knowledgeC.db", data)
        manifest["files"]["knowledgeC.db"]["sha256"] = b.hashlib.sha256(data).hexdigest()
        manifest["files"]["knowledgeC.db"]["size"] = len(data)
        raw = json.dumps(manifest).encode()
        self.unseal_file(dest, "manifest.json", raw)
        self.unseal_file(dest, "COMPLETE", b.hashlib.sha256(raw).hexdigest().encode())
        with self.assertRaisesRegex(b.StorageError, "integrity"): b.verify_backup(dest)

if __name__ == "__main__":
    unittest.main()
