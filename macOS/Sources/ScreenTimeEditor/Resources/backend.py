#!/usr/bin/env python3
"""Local, read-only-until-certified Screen Time storage backend.

All timestamps exposed by this module use seconds since 2001-01-01 UTC.
Apple does not publish a transactional writer for these stores. Consequently
production apply is deliberately disabled, rather than claiming atomicity across
Biome, CoreData and the live Apple writers. There is no fixture-root CLI switch.
"""
import hashlib
import json
import math
import os
from pathlib import Path
import sqlite3
import stat
import struct
import subprocess
import sys
import tempfile
import uuid
import zlib

COCOA_OFFSET = 978307200
MAX_SEGMENT = 64 * 1024 * 1024
MAX_INPUT = 4 * 1024 * 1024
APPLY_BLOCK_REASON = "No certified writer or coordinated multi-store rollback is available."

class StorageError(Exception):
    def __init__(self, message, code="storage_error"):
        super().__init__(message)
        self.code = code

def require(condition, message, code="unsupported_format"):
    if not condition:
        raise StorageError(message, code)

def finite(value):
    require(isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value) and -COCOA_OFFSET <= value <= 253402300799 - COCOA_OFFSET,
            "Timestamp must be finite and within supported calendar range.", "invalid_input")
    return float(value)

def varint(data, offset):
    value = 0
    for shift in range(0, 70, 7):
        require(offset < len(data), "Truncated protobuf varint.")
        byte = data[offset]
        offset += 1
        require(shift != 63 or byte <= 1, "Protobuf varint overflow.")
        value |= (byte & 127) << shift
        if not byte & 128:
            return value, offset
    raise StorageError("Protobuf varint overflow.")

def protobuf(data):
    fields = {}
    offset = 0
    while offset < len(data):
        key, offset = varint(data, offset)
        number, wire = key >> 3, key & 7
        require(0 < number <= 536870911, "Invalid protobuf field number.")
        if wire == 0:
            value, offset = varint(data, offset)
        elif wire in (1, 5):
            size = 8 if wire == 1 else 4
            require(offset + size <= len(data), "Truncated protobuf fixed-width field.")
            value = data[offset:offset + size]
            offset += size
        elif wire == 2:
            size, offset = varint(data, offset)
            require(size <= len(data) - offset, "Truncated protobuf length-delimited field.")
            value = data[offset:offset + size]
            offset += size
        else:
            raise StorageError("Unsupported protobuf wire type.")
        fields.setdefault(number, []).append((wire, value))
    return fields

def decode_usage(payload):
    fields = protobuf(payload)
    def one(number, wire):
        entries = fields.get(number, [])
        require(len(entries) == 1 and entries[0][0] == wire,
                "Unsupported AppUsage protobuf schema.")
        return entries[0][1]
    starting = one(1, 0)
    require(starting in (0, 1), "Unsupported AppUsage event state.")
    timestamp = finite(struct.unpack("<d", one(2, 1))[0] - COCOA_OFFSET)
    try:
        bundle = one(3, 2).decode("utf-8")
    except UnicodeError as exc:
        raise StorageError("Invalid AppUsage bundle encoding.") from exc
    require(bundle and len(bundle.encode()) <= 4096 and not any(ord(c) < 32 for c in bundle),
            "Invalid AppUsage bundle identifier.")
    return bool(starting), timestamp, bundle

def parse_segment(data):
    require(32 <= len(data) <= MAX_SEGMENT, "Invalid SEGB size.")
    magic, count, created, version, flags, reserved = struct.unpack_from("<4sIdIIQ", data)
    require(magic == b"SEGB" and version == 10, "Unsupported SEGB version.")
    finite(created)
    require(count <= (len(data) - 32) // 16, "SEGB footer exceeds capacity.")
    boundary = len(data) - 16 * count
    previous = 0
    records = []
    for index in range(count):
        end, state, timestamp = struct.unpack_from("<IId", data, len(data) - 16 * (index + 1))
        finite(timestamp)
        aligned = (previous + 3) & ~3
        require(state in (0, 1), "Unsupported SEGB record state.")
        if state == 0 and end == 0:
            records.append((state, timestamp, 0, b""))
            continue
        require(end >= aligned and 32 + end <= boundary, "SEGB payload/footer overlap or invalid offset.")
        if state == 1:
            require(end >= aligned + 8, "Truncated SEGB active record.")
            crc, flag = struct.unpack_from("<II", data, 32 + aligned)
            payload = data[32 + aligned + 8:32 + end]
            require(zlib.crc32(payload) & 0xffffffff == crc, "SEGB CRC mismatch.")
        else:
            flag, payload = 0, data[32 + aligned:32 + end]
        records.append((state, timestamp, flag, payload))
        previous = end
    return (created, version, flags, reserved, len(data)), records

def paired_sessions(events):
    opened, sessions, warnings = {}, [], []
    # Stable sort retains source record order for equal timestamps.
    for starting, timestamp, bundle, identity in sorted(events, key=lambda event: event[1]):
        if starting:
            require(bundle not in opened, "Overlapping unmatched starts prevent a complete AppUsage read.", "incomplete_read")
            opened[bundle] = (timestamp, identity)
        else:
            require(bundle in opened, "Unmatched AppUsage end prevents a complete read.", "incomplete_read")
            start, start_id = opened.pop(bundle)
            require(timestamp >= start, "AppUsage end precedes start.", "incomplete_read")
            sid = hashlib.sha256((start_id + "|" + identity).encode()).hexdigest()
            sessions.append(dict(id=sid, bundle=bundle, start=start, end=timestamp))
    if opened:
        warnings.append("Unclosed live AppUsage events are not editable sessions.")
    return sessions, warnings

def validate_edit(request):
    require(isinstance(request, dict), "Expected JSON object.", "invalid_input")
    start, end = finite(request.get("dayStart")), finite(request.get("dayEnd"))
    require(0 < end - start <= 90000, "Invalid day boundary (maximum 25 hours).", "invalid_input")
    revision = request.get("revision")
    require(isinstance(revision, str) and len(revision) == 64 and
            all(c in "0123456789abcdef" for c in revision), "Missing or invalid read revision.", "invalid_input")
    sessions = request.get("sessions")
    require(isinstance(sessions, list) and len(sessions) <= 10000, "Invalid sessions array.", "invalid_input")
    result, ids = [], set()
    for session in sessions:
        require(isinstance(session, dict), "Invalid session.", "invalid_input")
        identifier, bundle = session.get("id"), session.get("bundle")
        require(isinstance(identifier, str) and 0 < len(identifier) <= 256 and identifier not in ids,
                "Missing, duplicate or invalid session ID.", "invalid_input")
        ids.add(identifier)
        require(isinstance(bundle, str) and 0 < len(bundle.encode()) <= 4096
                and not any(ord(c) < 32 for c in bundle), "Invalid bundle.", "invalid_input")
        a, b = finite(session.get("start")), finite(session.get("end"))
        require(a < b, "Session end must follow start.", "invalid_input")
        require(start <= a < b <= end, "Edited sessions must be clipped to the requested day.", "invalid_input")
        result.append(dict(id=identifier, bundle=bundle, start=a, end=b))
    return start, end, result

def preserve_outside(sessions, start, end):
    """Split crossing sessions, retaining both outside portions unchanged."""
    result = []
    for session in sessions:
        a, b = session["start"], session["end"]
        if b <= start or a >= end:
            result.append(dict(session))
            continue
        if a < start:
            result.append(dict(session, end=start, id=session["id"] + "-before"))
        if b > end:
            result.append(dict(session, start=end, id=session["id"] + "-after"))
    return result

def no_symlink_parents(path):
    path = Path(os.path.abspath(str(path)))
    for parent in reversed((path,) + tuple(path.parents)):
        info = parent.lstat()
        require(not stat.S_ISLNK(info.st_mode), "Symlink path component refused.", "unsafe_path")
    return path

def checked_bytes(path):
    path = no_symlink_parents(path)
    before = path.lstat()
    require(stat.S_ISREG(before.st_mode) and not path.is_symlink(), "Source is not a regular non-symlink file.")
    require(before.st_size <= MAX_SEGMENT, "Source exceeds supported size.")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(fd)
        require((opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino), "Source replaced during read.", "concurrent_change")
        with os.fdopen(fd, "rb", closefd=False) as handle:
            data = handle.read(MAX_SEGMENT + 1)
        after = os.fstat(fd)
        require((before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                (after.st_size, after.st_mtime_ns, after.st_ctime_ns) and len(data) == before.st_size,
                "Source changed during read.", "concurrent_change")
        return data
    finally:
        os.close(fd)

class Engine:
    # home injection is a Python testing API only. CLI always supplies Path.home().
    def __init__(self, home):
        self.home = Path(home)
        self.stream = self.home / "Library/Biome/streams/restricted/ScreenTime.AppUsage/local"
        self.database = self.home / "Library/Application Support/Knowledge/knowledgeC.db"

    def source_paths(self):
        try:
            info = no_symlink_parents(self.stream).stat()
        except FileNotFoundError as exc:
            raise StorageError("AppUsage directory missing.", "read_failed") from exc
        except PermissionError as exc:
            raise StorageError("Permission denied reading AppUsage directory.", "permission_denied") from exc
        require(stat.S_ISDIR(info.st_mode), "AppUsage path is not a directory.", "read_failed")
        result = []
        for path in sorted(self.stream.iterdir()):
            # These are known directory metadata, not event segments.
            if path.name in ("lock", "tombstone") or path.name.startswith("."):
                continue
            require(path.is_file() and not path.is_symlink(), "Unsupported entry in AppUsage directory.")
            result.append(path)
        require(result, "No AppUsage segments found.", "read_failed")
        require(len(result) <= 10000, "Too many AppUsage segments.")
        return result

    def open_database(self):
        try:
            info = no_symlink_parents(self.database).stat()
        except FileNotFoundError as exc:
            raise StorageError("knowledgeC database missing.", "read_failed") from exc
        except PermissionError as exc:
            raise StorageError("Permission denied reading knowledgeC.", "permission_denied") from exc
        require(stat.S_ISREG(info.st_mode), "knowledgeC is not a regular file.", "read_failed")
        try:
            conn = sqlite3.connect(self.database.as_uri() + "?mode=ro", uri=True, timeout=2)
            conn.execute("PRAGMA query_only=ON")
            conn.execute("BEGIN")
            conn.execute("SELECT name FROM sqlite_master LIMIT 1").fetchall()
            return conn
        except sqlite3.Error as exc:
            if "conn" in locals():
                conn.close()
            raise StorageError("Cannot read knowledgeC: " + str(exc), "read_failed") from exc

    def fingerprint(self):
        digest = hashlib.sha256()
        paths = self.source_paths()
        for path in paths:
            digest.update(path.name.encode() + b"\0" + hashlib.sha256(checked_bytes(path)).digest())
        for suffix in ("", "-wal", "-shm"):
            path = Path(str(self.database) + suffix)
            digest.update(suffix.encode() + b"\0")
            if path.exists():
                # shm is SQLite coordination, not logical data; hashing it creates
                # false stale reads on every read-only connection. Track existence only.
                if suffix != "-shm":
                    digest.update(hashlib.sha256(checked_bytes(path)).digest())
            else:
                digest.update(b"absent")
        return digest.hexdigest()

    def read(self):
        try:
            before = self.fingerprint()
            events = []
            for path in self.source_paths():
                _, records = parse_segment(checked_bytes(path))
                for index, (state, timestamp, flag, payload) in enumerate(records):
                    if state == 1:
                        starting, when, bundle = decode_usage(payload)
                        require(abs(when - timestamp) <= 0.001, "AppUsage record/payload timestamp mismatch.")
                        events.append((starting, when, bundle, path.name + ":" + str(index)))
            conn = self.open_database()
            try:
                columns = {row[1] for row in conn.execute("PRAGMA table_info(ZOBJECT)")}
                require({"ZSTREAMNAME", "ZSTARTDATE", "ZENDDATE", "ZVALUESTRING"} <= columns,
                        "Unsupported knowledgeC schema.")
                # Force access to real usage rows, not only the schema.
                conn.execute("SELECT ZSTARTDATE,ZENDDATE,ZVALUESTRING FROM ZOBJECT WHERE ZSTREAMNAME=?",
                             ("/app/usage",)).fetchall()
            finally:
                conn.close()
            sessions, warnings = paired_sessions(events)
            after = self.fingerprint()
            require(before == after, "Sources changed during read; retry.", "concurrent_change")
            warnings.append("Native Screen Time UI aggregation and cross-device synchronization are not verified.")
            warnings.append("Apply is disabled: no certified atomic writer for this live Apple storage layout.")
            return dict(sessions=sessions, revision=after, warnings=warnings, canApply=False, applyBlockReason=APPLY_BLOCK_REASON, supportedWriters=[])
        except OSError as exc:
            raise StorageError("Cannot read local Screen Time stores: " + str(exc), "read_failed") from exc
        except sqlite3.Error as exc:
            raise StorageError("Cannot read knowledgeC: " + str(exc), "read_failed") from exc

    def apply(self, request):
        validate_edit(request)
        snapshot = self.read()
        require(snapshot["revision"] == request["revision"], "Sources changed since loading; reload before applying.", "stale_revision")
        # Never write a partial approximation or manufacture success. A backup
        # alone cannot make multiple live Apple stores transactional.
        raise StorageError("Apply blocked: Apple writer coordination, CoreData entity allocation and multi-store rollback are not certified for this macOS layout. No data was changed.", "unsupported_write_layout")

def private_file(path, data):
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                 getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())

def sync_directory(path):
    fd = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def verify_backup(destination, expected_revision=None):
    """Validate a sealed complete snapshot independently before any future writer.

    This is tamper detection, not authentication against the owning account.
    No production writer currently exists. Never infer authorization from this.
    """
    destination = no_symlink_parents(destination)
    info = destination.lstat()
    require(stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o500
            and info.st_uid == os.getuid(), "Backup directory is not sealed/private.", "backup_failed")
    entries = {p.name: p for p in destination.iterdir()}
    require("manifest.json" in entries and "COMPLETE" in entries and
            "INVALID" not in entries, "Backup is incomplete or invalid.", "backup_failed")
    for path in entries.values():
        info = path.lstat()
        require(stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o400
                and info.st_uid == os.getuid() and info.st_nlink == 1,
                "Backup entry is not a private sealed regular file.", "backup_failed")
    raw = checked_bytes(entries["manifest.json"])
    require(checked_bytes(entries["COMPLETE"]) == hashlib.sha256(raw).hexdigest().encode(),
            "Backup completion digest mismatch.", "backup_failed")
    try:
        manifest = json.loads(raw)
    except (ValueError, UnicodeError) as exc:
        raise StorageError("Invalid backup manifest.", "backup_failed") from exc
    require(isinstance(manifest, dict) and set(manifest) == {"version", "revision", "files"}
            and manifest["version"] == 2, "Unsupported backup manifest schema.", "backup_failed")
    revision = manifest["revision"]
    require(isinstance(revision, str) and len(revision) == 64 and
            all(c in "0123456789abcdef" for c in revision),
            "Invalid backup revision.", "backup_failed")
    require(expected_revision is None or revision == expected_revision,
            "Backup revision does not match requested snapshot.", "backup_failed")
    files = manifest["files"]
    require(isinstance(files, dict) and 2 <= len(files) <= 10001 and
            "knowledgeC.db" in files and set(entries) == set(files) | {"manifest.json", "COMPLETE"},
            "Backup file inventory mismatch.", "backup_failed")
    for name, record in files.items():
        require(isinstance(name, str) and (name == "knowledgeC.db" or
                (name.startswith("segment-") and name[8:].isdigit() and name[8:].isascii())),
                "Unsafe backup filename.", "backup_failed")
        require(isinstance(record, dict) and set(record) == {"source", "sha256", "size"} and
                isinstance(record["source"], str) and record["source"].startswith("/") and
                ".." not in Path(record["source"]).parts and
                isinstance(record["size"], int) and not isinstance(record["size"], bool) and
                0 <= record["size"] <= MAX_SEGMENT and isinstance(record["sha256"], str),
                "Invalid backup file metadata.", "backup_failed")
        data = checked_bytes(destination / name)
        require(len(data) == record["size"] and hashlib.sha256(data).hexdigest() == record["sha256"],
                "Backup file digest mismatch.", "backup_failed")
    database = destination / "knowledgeC.db"
    try:
        # immutable avoids creating SQLite journal/WAL/SHM in the sealed snapshot.
        conn = sqlite3.connect(database.as_uri() + "?mode=ro&immutable=1", uri=True)
        try:
            require(conn.execute("PRAGMA integrity_check").fetchall() == [("ok",)],
                    "Backup SQLite integrity failed.", "backup_failed")
        finally:
            conn.close()
    except sqlite3.Error as exc:
        raise StorageError("Backup SQLite integrity failed.", "backup_failed") from exc
    return manifest

def verified_backup(engine, destination):
    """Create a durable, complete private snapshot; never enables apply."""
    destination = Path(os.path.abspath(str(destination)))
    no_symlink_parents(destination.parent)
    require(not os.path.lexists(destination), "Backup destination already exists.", "backup_failed")
    before = engine.fingerprint()
    destination.mkdir(mode=0o700)
    os.chmod(destination, 0o700)
    private_file(destination / "INVALID", b"Incomplete snapshot; do not restore or authorize writes.")
    sync_directory(destination)
    manifest = {"version": 2, "revision": before, "files": {}}
    try:
        for index, source in enumerate(engine.source_paths()):
            name = "segment-" + str(index)
            data = checked_bytes(source)
            private_file(destination / name, data)
            manifest["files"][name] = dict(source=str(source), sha256=hashlib.sha256(data).hexdigest(), size=len(data))
        database_copy = destination / "knowledgeC.db"
        # Precreate with 0600, before SQLite opens it, independent of umask.
        private_file(database_copy, b"")
        source = engine.open_database()
        try:
            target = sqlite3.connect(str(database_copy))
            try:
                source.backup(target)
                require(target.execute("PRAGMA journal_mode=DELETE").fetchone() == ("delete",),
                        "Backup could not leave WAL mode.", "backup_failed")
                require(target.execute("PRAGMA integrity_check").fetchall() == [("ok",)],
                        "Backup SQLite integrity failed.", "backup_failed")
            finally:
                target.close()
        finally:
            source.close()
        # SQLite backup from a WAL database may leave its own coordination
        # sidecars. All target connections are closed and DELETE mode confirmed.
        for suffix in ("-wal", "-shm"):
            sidecar = Path(str(database_copy) + suffix)
            if os.path.lexists(sidecar):
                require(stat.S_ISREG(sidecar.lstat().st_mode) and not sidecar.is_symlink(),
                        "Unsafe snapshot sidecar.", "backup_failed")
                sidecar.unlink()
        data = checked_bytes(database_copy)
        fd = os.open(str(database_copy), os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        manifest["files"]["knowledgeC.db"] = dict(source=str(engine.database),
            sha256=hashlib.sha256(data).hexdigest(), size=len(data))
        require(engine.fingerprint() == before, "Sources changed during backup.", "concurrent_change")
        raw = json.dumps(manifest, sort_keys=True).encode()
        private_file(destination / "manifest.json", raw)
        private_file(destination / "COMPLETE", hashlib.sha256(raw).hexdigest().encode())
        sync_directory(destination)
        (destination / "INVALID").unlink()
        for path in destination.iterdir():
            os.chmod(path, 0o400)
            fd = os.open(str(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        os.chmod(destination, 0o500)
        sync_directory(destination)
        sync_directory(destination.parent)
        return verify_backup(destination, before)
    except Exception:
        # Never leave a failed snapshot appearing complete, even if final verify fails.
        os.chmod(destination, 0o700)
        marker = destination / "INVALID"
        if not os.path.lexists(marker):
            private_file(marker, b"Snapshot failed validation; do not use.")
        sync_directory(destination)
        raise

def status(runner=subprocess.run):
    def command(args):
        try:
            result = runner(args, capture_output=True, text=True, timeout=10, check=False)
            if result.returncode:
                return None, (result.stderr or result.stdout).strip() or "Command failed"
            return result.stdout.strip(), None
        except (OSError, subprocess.SubprocessError) as exc:
            return None, str(exc)
    version, ve = command(["/usr/bin/sw_vers", "-productVersion"])
    build, be = command(["/usr/bin/sw_vers", "-buildVersion"])
    details, se = command(["/usr/bin/csrutil", "status"])
    sip = "unknown"
    if details and "System Integrity Protection status: enabled." in details:
        sip = "enabled"
    elif details and "System Integrity Protection status: disabled." in details:
        sip = "disabled"
    return dict(macOS=version or "unknown", build=build or "unknown", sip=sip, sipDetails=details or se,
                warnings=[error for error in (ve, be) if error], canApply=False, applyBlockReason=APPLY_BLOCK_REASON, supportedWriters=[])

def main():
    try:
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        require(len(raw) <= MAX_INPUT, "Request exceeds size limit.", "invalid_input")
        request = json.loads(raw, parse_constant=lambda value: (_ for _ in ()).throw(ValueError("Non-finite JSON number")))
        require(isinstance(request, dict), "Expected JSON object.", "invalid_input")
        command = request.get("command")
        engine = Engine(Path.home())
        if command == "status":
            result = status()
        elif command == "read":
            result = engine.read()
        elif command == "apply":
            result = engine.apply(request)
        else:
            raise StorageError("Unknown command.", "invalid_input")
        print(json.dumps(result, allow_nan=False))
        return 0
    except (StorageError, ValueError, TypeError, OSError) as exc:
        print(json.dumps(dict(error=str(exc), code=getattr(exc, "code", "invalid_input"))))
        return 1

if __name__ == "__main__":
    sys.exit(main())
