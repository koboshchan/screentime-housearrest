"""Local mechanism adapted from verified private backup 20261016-054202,
scripts/inject_local_mac.py. No execution at import, remote access, credentials,
hardcoded home fallback or daemon termination. Original latest-segment and
Z_ENT=1 insertion behavior retained; native aggregation may require logout.
"""
import os
import sqlite3
import struct
import zlib


def build_segb_v2(header, records, api):
    created, version, flags, reserved, size = header
    boundary = size - 16 * len(records)
    api.require(boundary >= 32, 'Edited events exceed segment capacity.', 'segment_capacity')
    offset = 0
    for state, timestamp, flag, payload in records:
        aligned = (offset + 3) & ~3
        end = aligned + len(payload) + (8 if state == 1 else 0)
        if state == 0 and not payload:
            continue
        api.require(32 + end <= boundary, 'Edited events exceed segment capacity.', 'segment_capacity')
        offset = end
    data = bytearray(size)
    struct.pack_into('<4sIdIIQ', data, 0, b'SEGB', len(records), created, version, flags, reserved)
    offset = 0
    for index, (state, timestamp, flag, payload) in enumerate(records):
        aligned = (offset + 3) & ~3
        if state == 1:
            struct.pack_into('<II', data, 32 + aligned, zlib.crc32(payload) & 0xffffffff, flag)
            start = 40 + aligned
        else:
            start = 32 + aligned
        end = aligned + len(payload) + (8 if state == 1 else 0)
        if state == 0 and not payload:
            end = 0
        else:
            data[start:start + len(payload)] = payload
            offset = end
        struct.pack_into('<IId', data, size - 16 * (index + 1), end, state, timestamp)
    api.parse_segment(data)
    return bytes(data)


def usage_payload(starting, timestamp, bundle, api):
    raw = bundle.encode('utf-8')
    number = len(raw)
    encoded = bytearray()
    while number >= 128:
        encoded.append((number & 127) | 128); number >>= 7
    encoded.append(number)
    return b'\x08' + bytes([int(starting)]) + b'\x11' + struct.pack('<d', timestamp + api.COCOA_OFFSET) + b'\x1a' + bytes(encoded) + raw + b'\x28\x01'


def prepare(engine, start, end, sessions, api):
    # Preserve original scope: only the latest local AppUsage segment is edited.
    path = engine.source_paths()[-1]
    raw = api.checked_bytes(path)
    header, records = api.parse_segment(raw)
    events = []
    for index, (state, timestamp, flag, payload) in enumerate(records):
        if state == 1:
            opening, when, bundle = api.decode_usage(payload)
            events.append((opening, when, bundle, str(index)))
    existing, warnings = api.paired_sessions(events)
    outside = []
    for session in existing:
        if session['end'] > start and session['start'] < end:
            outside.extend(api.preserve_outside([session], start, end))
    kept = [record for record in records if record[1] < start or record[1] >= end]
    # Remove both endpoints of crossing sessions before rebuilding outside pieces.
    remove = set()
    for session in existing:
        if session['end'] > start and session['start'] < end:
            remove.update(((session['bundle'],session['start']), (session['bundle'],session['end'])))
    kept = [r for r in kept if r[0] != 1 or (api.decode_usage(r[3])[2], r[1]) not in remove]
    for session in list(sessions) + outside:
        for opening, when in ((True,session['start']), (False,session['end'])):
            kept.append((1,when,0,usage_payload(opening,when,session['bundle'],api)))
    kept.sort(key=lambda r: r[1])
    serialized = build_segb_v2(header, kept, api)
    conn = engine.open_database()
    try:
        columns = {row[1] for row in conn.execute('PRAGMA table_info(ZOBJECT)')}
        api.require({'Z_ENT','Z_OPT','ZSTREAMNAME','ZSTARTDATE','ZENDDATE','ZVALUESTRING','ZCREATIONDATE'} <= columns,
                    'Original writer requires knowledgeC insertion columns.', 'unsupported_schema')
        database_sessions = list(sessions)
        for a,b,bundle in conn.execute("SELECT ZSTARTDATE,ZENDDATE,ZVALUESTRING FROM ZOBJECT WHERE ZSTREAMNAME='/app/usage' AND ZENDDATE>? AND ZSTARTDATE<?",(start,end)):
            api.finite(a); api.finite(b)
            if a < start: database_sessions.append(dict(start=a,end=start,bundle=bundle))
            if b > end: database_sessions.append(dict(start=end,end=b,bundle=bundle))
    finally:
        conn.close()
    return dict(path=path, original=raw, serialized=serialized, sessions=database_sessions, start=start, end=end)


def inject_local(engine, plan, api):
    # Called ONLY after verified backup and revision recheck by Engine.apply.
    # Two stores are not a single transaction. Failures report possible partial
    # changes and backup location; never claim rollback that did not happen.
    path = api.no_symlink_parents(plan['path'])
    api.require(api.checked_bytes(path) == plan['original'], 'Segment changed before write.', 'concurrent_change')
    api.no_symlink_parents(engine.database)
    before = path.stat()
    conn = sqlite3.connect(engine.database.as_uri()+'?mode=rw', uri=True, timeout=2)
    try:
        conn.execute('BEGIN IMMEDIATE')
        conn.execute("DELETE FROM ZOBJECT WHERE ZSTREAMNAME='/app/usage' AND ZENDDATE>? AND ZSTARTDATE<?",(plan['start'],plan['end']))
        for session in plan['sessions']:
            conn.execute("INSERT INTO ZOBJECT (Z_ENT,Z_OPT,ZSTREAMNAME,ZSTARTDATE,ZENDDATE,ZVALUESTRING,ZCREATIONDATE) VALUES (1,1,'/app/usage',?,?,?,?)",(session['start'],session['end'],session['bundle'],session['start']))
        fd=os.open(path,os.O_WRONLY | getattr(os,'O_NOFOLLOW',0))
        try:
            opened = os.fstat(fd)
            api.require((opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns) ==
                        (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns),
                        'Segment replaced before write.', 'concurrent_change')
            with os.fdopen(fd,'wb',closefd=False) as handle:
                handle.write(plan['serialized']); handle.flush(); os.ftruncate(fd,len(plan['serialized'])); os.fsync(fd)
        finally:
            os.close(fd)
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
    return 'SUCCESS_LOGOUT_REQUIRED'
