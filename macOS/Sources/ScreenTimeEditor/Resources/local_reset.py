"""SIP-off local reset, adapted from the private original injector.
No remote access, stored credentials, permission changes or import side effects.
A signed one-shot helper authorizes fixed system Backlight access only.
"""
from contextlib import nullcontext
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import stat
import struct
import subprocess

# Only the immutable signed helper supplies a scoped effective-UID context.
# Normal app/backend processes cannot elevate through this hook.
system_privileges = nullcontext

PROCESSES = ('System Settings', 'ScreenTimePreferencesExtension',
             'UsageTrackingAgent', 'ScreenTimeAgent')

def discover(engine, api):
    backlight = Path('/private/var/db/biome/streams/restricted/Device.Display.Backlight/local')
    # Darwin supplies the CURRENT user's directory; never search other users.
    # CPython does not expose Apple's CS_DARWIN_USER_DIR in confstr_names.
    # The native utility resolves the same key for the current user.
    try:
        result = subprocess.run(
            ['/usr/bin/getconf', 'DARWIN_USER_DIR'],
            capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        api.require(False, 'Cannot locate current-user Darwin cache: getconf failed.',
                    'reset_unavailable')
    directory = (result.stdout or '').strip()
    api.require(result.returncode == 0 and not (result.stderr or '').strip()
                and directory and '\n' not in directory and '\r' not in directory
                and '\0' not in directory and Path(directory).is_absolute()
                and Path(directory) != Path('/'),
                'Cannot locate current-user Darwin cache: invalid getconf result.',
                'reset_unavailable')
    cache = Path(directory).resolve() / 'com.apple.ScreenTimeAgent/Store/Library/com.apple.DeviceActivity/Local'
    return backlight, cache

def inventory(backlight, cache, api):
    with system_privileges():
        api.no_symlink_parents(backlight)
        api.require(backlight.is_dir(), 'Backlight stream missing.', 'reset_unavailable')
        files = {}
        for path in sorted(backlight.iterdir()):
            if path.name.startswith('.') or path.name in ('lock', 'tombstone'):
                continue
            api.require(path.is_file() and not path.is_symlink(), 'Unsafe backlight entry.', 'unsafe_path')
            api.parse_segment(api.checked_bytes(path))
            files['backlight/' + path.name] = path
        api.require(files, 'No backlight segments found.', 'reset_unavailable')
        api.require(len(files) <= 10000, 'Too many backlight segments.', 'reset_unavailable')
    directories = []
    # Check ancestors even when Local does not exist, avoiding dangling symlinks.
    ancestor = cache
    while not os.path.lexists(ancestor):
        ancestor = ancestor.parent
    api.no_symlink_parents(ancestor)
    exists = os.path.lexists(cache)
    if exists:
        api.no_symlink_parents(cache)
        api.require(cache.is_dir(), 'DeviceActivity cache is not a directory.', 'unsafe_path')
        def walk(path):
            api.require(len(files) + len(directories) < 100000, 'Cache inventory too large.', 'reset_unavailable')
            info = path.lstat()
            api.require(not stat.S_ISLNK(info.st_mode), 'Cache symlink refused.', 'unsafe_path')
            if stat.S_ISDIR(info.st_mode):
                directories.append(dict(path=str(path.relative_to(cache)), mode=stat.S_IMODE(info.st_mode),
                                        uid=info.st_uid, gid=info.st_gid))
                for child in sorted(path.iterdir()):
                    walk(child)
            else:
                api.require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
                            'Nonregular or hardlinked cache entry refused.', 'unsafe_path')
                files['cache/' + str(path.relative_to(cache))] = path
        walk(cache)
    state = dict(backlight=str(backlight), cache=str(cache), cacheExists=exists, directories=directories)
    for key, path in files.items():
        with system_privileges() if key.startswith('backlight/') else nullcontext():
            info = path.stat()
            size, digest = api.file_digest(path)
        state.setdefault('files', {})[key] = dict(source=str(path), mode=stat.S_IMODE(info.st_mode),
            uid=info.st_uid, gid=info.st_gid, size=size, sha256=digest)
    return state, files

def prepare(engine, start, end, sessions, api, paths=None):
    backlight, cache = paths if paths is not None else discover(engine, api)
    try:
        state, files = inventory(backlight, cache, api)
    except PermissionError as exc:
        system_store = (exc.filename is not None and
                        (Path(exc.filename) == backlight or Path(exc.filename) in backlight.parents))
        if system_store:
            raise api.StorageError(
                "System Biome storage is not accessible to this account. "
                "SIP being disabled does not grant filesystem privileges. "
                "Full Disk Access may already be enabled; an authorized privileged "
                "helper is required when the system folder is owned by _biome. "
                "No Screen Time stores were changed.",
                "system_store_permission_denied") from exc
        raise api.StorageError(
            "Screen Time reset storage access was denied. Check Full Disk Access "
            "for Screen Time Editor, then quit and reopen the app. "
            "No Screen Time stores were changed.", "permission_denied") from exc
    conn = engine.open_database()
    try:
        api.require('ZVALUEINTEGER' in {r[1] for r in conn.execute('PRAGMA table_info(ZOBJECT)')},
                    'Backlight writer requires knowledgeC ZVALUEINTEGER.', 'unsupported_schema')
    finally: conn.close()
    light = [(key, path) for key, path in files.items() if key.startswith('backlight/')]
    # Original remote script targets one hardcoded Backlight segment.
    # Local adaptation resolves one latest lexically named segment, matching
    # inject_local_mac.latest_segb_file, not header creation-time heuristics.
    with system_privileges():
        parsed = [(path, api.checked_bytes(path)) for _, path in light]
    latest = max(parsed, key=lambda item: item[0].name)[0]
    edits = []
    for path, raw in parsed:
        if path != latest:
            continue
        header, records = api.parse_segment(raw)
        kept = [r for r in records if r[1] < start or r[1] >= end]
        if path == latest:
            for session in sessions:
                for when, on in ((session['start'], 1), (session['end'], 0)):
                    kept.append((1, when, 0, b'\x09' + struct.pack('<d', when) + b'\x10' + bytes([on])))
        kept.sort(key=lambda r: r[1])
        serialized = api.original_local.build_segb_v2(header, kept, api)
        if serialized != raw:
            edits.append((path, raw, serialized))
    return dict(state=state, files=files, edits=edits, backlight=backlight, cache=cache,
                start=start, end=end, sessions=sessions)

def snapshot(plan, destination, api):
    """Separate sealed reset snapshot; source inventory and bytes rechecked."""
    destination.mkdir(mode=0o700)
    api.private_file(destination/'INVALID', b'incomplete reset snapshot')
    try:
        state = dict(plan['state'])
        state['files'] = {key:dict(record) for key,record in state.get('files', {}).items()}
        for index,(key,path) in enumerate(sorted(plan['files'].items())):
            name = 'file-' + str(index)
            if key.startswith('backlight/'):
                with system_privileges():
                    raw = api.checked_bytes(path)
                api.private_file(destination/name, raw)
                size, digest = len(raw), hashlib.sha256(raw).hexdigest()
            else:
                size,digest = api.copy_private(path, destination/name)
            record = state['files'][key]
            api.require((size,digest)==(record['size'],record['sha256']),
                        'Reset source changed before backup.', 'backup_failed')
            record['backup'] = name
        current,_ = inventory(plan['backlight'],plan['cache'],api)
        api.require(current == plan['state'], 'Reset source changed during backup.', 'backup_failed')
        raw = json.dumps(state,sort_keys=True).encode()
        api.private_file(destination/'manifest.json',raw)
        api.private_file(destination/'COMPLETE',hashlib.sha256(raw).hexdigest().encode())
        (destination/'INVALID').unlink()
        for path in destination.iterdir():
            os.chmod(path,0o400)
            with path.open('rb') as f: os.fsync(f.fileno())
        os.chmod(destination,0o500)
        api.sync_directory(destination)
        api.sync_directory(destination.parent)
        return verify(destination,plan,api)
    except Exception:
        os.chmod(destination,0o700)
        if not (destination/'INVALID').exists():
            api.private_file(destination/'INVALID',b'reset snapshot verification failed')
        raise

def verify(destination, plan, api):
    api.no_symlink_parents(destination)
    info = destination.stat()
    api.require(stat.S_IMODE(info.st_mode)==0o500 and info.st_uid==os.getuid(),
                'Reset backup not sealed/private.', 'backup_failed')
    entries = {p.name:p for p in destination.iterdir()}
    api.require('INVALID' not in entries and {'manifest.json','COMPLETE'} <= set(entries),
                'Reset backup incomplete.', 'backup_failed')
    for path in entries.values():
        info = path.lstat()
        api.require(stat.S_ISREG(info.st_mode) and info.st_nlink==1 and
                    info.st_uid==os.getuid() and stat.S_IMODE(info.st_mode)==0o400,
                    'Unsafe reset backup entry.', 'backup_failed')
    raw = api.checked_bytes(entries['manifest.json'])
    api.require(api.checked_bytes(entries['COMPLETE']) == hashlib.sha256(raw).hexdigest().encode(),
                'Reset completion digest mismatch.', 'backup_failed')
    state = json.loads(raw)
    expected = json.loads(json.dumps(plan['state']))
    names = set()
    for key,record in state.get('files',{}).items():
        name = record.pop('backup',None)
        api.require(isinstance(name,str) and name.startswith('file-') and name[5:].isascii()
                    and name[5:].isdigit() and name not in names, 'Invalid reset backup inventory.', 'backup_failed')
        names.add(name)
        api.require(name in entries and api.file_digest(entries[name]) == (record['size'],record['sha256']),
                    'Reset backup bytes mismatch.', 'backup_failed')
    api.require(state == expected and set(entries)==names|{'manifest.json','COMPLETE'},
                'Reset backup state mismatch.', 'backup_failed')
    return state

def preflight(plan, api, access=os.access):
    # Only the sealed helper supplies scoped system privileges; user cache stays user-owned.
    with system_privileges():
        for path,raw,_ in plan['edits']:
            api.no_symlink_parents(path)
            api.require(api.checked_bytes(path)==raw, 'Backlight changed before reset.', 'concurrent_change')
            api.require((os.access(path, os.W_OK, effective_ids=True) if system_privileges is not nullcontext else access(path,os.W_OK)), 'Backlight write denied after authorization.', 'permission_denied')
    cache = plan['cache']
    if plan['state']['cacheExists']:
        for path in [cache.parent] + [cache / d['path'] for d in plan['state']['directories']]:
            api.require(access(path,os.W_OK|os.X_OK), 'Current-user DeviceActivity reset denied.', 'permission_denied')
    current,_ = inventory(plan['backlight'],cache,api)
    api.require(current == plan['state'], 'Reset stores changed after backup.', 'concurrent_change')

def stop_processes(api, runner=subprocess.run):
    for name in PROCESSES:
        result = runner(['/usr/bin/pkill','-9','-u',str(os.getuid()),'-x',name],
                        capture_output=True,text=True,timeout=10,check=False)
        # pkill 1 means no matching process, NOT success if it reports an error.
        api.require(result.returncode in (0,1) and not (result.stderr or '').strip(),
                    'Could not stop '+name+': '+(result.stderr or '').strip(), 'reset_failed')

def perform(engine, plan, api, runner=subprocess.run):
    # All calls happen after both snapshots verified independently and preflight.
    with system_privileges():
        for path,original,serialized in plan['edits']:
            api.no_symlink_parents(path)
            api.require(api.checked_bytes(path)==original,'Backlight changed before write.','concurrent_change')
            before=path.stat()
            api.require(before.st_nlink == 1, 'Hardlinked backlight refused.', 'unsafe_path')
            fd=os.open(path,os.O_WRONLY|getattr(os,'O_NOFOLLOW',0))
            try:
                now=os.fstat(fd)
                api.require((now.st_dev,now.st_ino,now.st_size,now.st_mtime_ns,now.st_ctime_ns)==
                            (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns),
                            'Backlight replaced before write.','concurrent_change')
                with os.fdopen(fd,'wb',closefd=False) as f:
                    f.write(serialized); f.flush(); os.ftruncate(fd,len(serialized)); os.fsync(fd)
            finally: os.close(fd)
            api.require(api.checked_bytes(path)==serialized,'Backlight write verification failed.','reset_failed')
    with sqlite3.connect(engine.database.as_uri()+'?mode=rw',uri=True,timeout=2) as conn:
        conn.execute("DELETE FROM ZOBJECT WHERE ZSTREAMNAME='/display/isBacklit' AND ZENDDATE>? AND ZSTARTDATE<?",
                     (plan['start'],plan['end']))
        for s in plan['sessions']:
            conn.execute("INSERT INTO ZOBJECT (Z_ENT,Z_OPT,ZSTREAMNAME,ZSTARTDATE,ZENDDATE,ZVALUEINTEGER,ZCREATIONDATE) VALUES (1,1,'/display/isBacklit',?,?,1,?)",
                         (s['start'],s['end'],s['start']))
    # Delete only enumerated files/dirs, never follow a new symlink or recurse
    # into entries introduced after backup. Unexpected new entries make rmdir fail.
    cache=plan['cache']
    for key,path in plan['files'].items():
        if key.startswith('cache/'):
            api.no_symlink_parents(path)
            record=plan['state']['files'][key]
            api.require(api.file_digest(path)==(record['size'],record['sha256']),
                        'Cache changed since backup.','concurrent_change')
            path.unlink()
    for d in sorted(plan['state']['directories'],key=lambda d:len(Path(d['path']).parts),reverse=True):
        path=cache/d['path']
        api.no_symlink_parents(path)
        path.rmdir()
    api.require(not os.path.lexists(cache),'DeviceActivity cache reset incomplete.','reset_failed')
    result = runner(['/bin/launchctl','kickstart','-k',
                     'gui/'+str(os.getuid())+'/com.apple.UsageTrackingAgent'],
                    capture_output=True,text=True,timeout=10,check=False)
    api.require(result.returncode == 0, 'UsageTrackingAgent restart failed: '+(result.stderr or '').strip(), 'reset_failed')
    return 'SUCCESS_RESET_COMPLETED'

def authorized_apply(request, api):
    """Launch only the signed embedded helper through a user-approved prompt.

    Stage a private root-owned copy before signature verification/execution so a
    user-writable bundle cannot be swapped after verification. No persistent
    service, password storage, root Python file or arbitrary command API exists.
    """
    import base64
    import shlex
    api.require(isinstance(request, dict) and not
                (set(request) - {'command', 'dayStart', 'dayEnd', 'sessions',
                                 'revision', 'overrideSourceChanges'}),
                'Unsupported administrator Apply fields.', 'invalid_input')
    helper = Path(__file__).resolve()
    parents = [p for p in helper.parents if p.suffix == '.app']
    api.require(len(parents) == 1, 'Administrator Apply requires the signed app bundle.',
                'admin_helper_unavailable')
    executable = parents[0] / 'Contents/MacOS/ScreenTimeAdminHelper'
    api.no_symlink_parents(executable)
    api.require(executable.is_file(), 'Signed administrator helper is missing.',
                'admin_helper_unavailable')
    # Bundle location and environment are not authority. Independently verify
    # the signed enclosing app, then the pinned helper inside its resource seal.
    identity = 'certificate leaf = H"5BAC8837B31A6449CA39EFA3CB494F24AD366428"'
    for target, identifier in ((parents[0], 'app.screentimeeditor.macos'),
                               (executable, 'ScreenTimeAdminHelper')):
        requirement_check = '=identifier "' + identifier + '" and ' + identity
        checked = subprocess.run(['/usr/bin/codesign', '--verify', '--strict',
                                  '-R', requirement_check, str(target)],
                                 capture_output=True, text=True, check=False)
        api.require(checked.returncode == 0,
                    'Administrator Apply requires the intact signed app and helper.',
                    'admin_helper_unavailable')
    raw = json.dumps(dict(request, command='apply'), allow_nan=False).encode()
    api.require(len(raw) <= 65536, 'Apply request exceeds administrator transport limit.',
                'invalid_input')
    payload = base64.b64encode(raw).decode('ascii')
    # This persistent local signing certificate is also pinned by signing.sh.
    # A changed signing identity must deliberately update this build-time pin.
    requirement = '=identifier "ScreenTimeAdminHelper" and certificate leaf = H"5BAC8837B31A6449CA39EFA3CB494F24AD366428"'
    q = shlex.quote
    shell = (
        'set -eu; umask 077; '
        'd=$(/usr/bin/mktemp -d /private/var/tmp/ScreenTimeAdmin.XXXXXXXX); '
        'trap \'/bin/rm -rf "$d"\' EXIT; '
        '/bin/cp '+q(str(executable))+' "$d/helper"; '
        '/bin/chmod 500 "$d/helper"; '
        '/usr/bin/codesign --verify --strict -R '+q(requirement)+' "$d/helper" >&2; '
        '"$d/helper" '+q(payload)+' '+str(os.getuid())+' || true')
    # JSON string quoting is valid AppleScript for these ASCII escaped strings.
    script = 'do shell script ' + json.dumps(shell, ensure_ascii=False) + ' with administrator privileges'
    result = subprocess.run(['/usr/bin/osascript', '-e', script],
                            capture_output=True, text=True, check=False)
    try:
        response = json.loads(result.stdout)
    except (ValueError, TypeError):
        message = (result.stderr or '').strip()
        cancelled = '-128' in message or 'canceled' in message.lower() or 'cancelled' in message.lower()
        raise api.StorageError(
            'Administrator authorization cancelled; no stores changed.' if cancelled else
            'Administrator Apply did not complete. '+message,
            'admin_cancelled' if cancelled else 'admin_apply_failed')
    api.require(isinstance(response, dict), 'Invalid administrator response.', 'admin_apply_failed')
    if result.returncode or response.get('error'):
        raise api.StorageError(response.get('error', 'Administrator Apply failed.'),
                               response.get('code', 'admin_apply_failed'))
    return response
