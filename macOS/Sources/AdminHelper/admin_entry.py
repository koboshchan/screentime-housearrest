"""Embedded in the signed helper, never loaded as an external root script."""
import contextlib
import json
import os
import pwd
import sys
import types

def entry(sources, encoded, uid_text):
    import base64
    if os.geteuid() != 0 or not uid_text.isascii() or not uid_text.isdigit():
        raise ValueError('Native administrator authorization is required.')
    uid = int(uid_text)
    if not 501 <= uid < 2147483647:
        raise ValueError('Invalid user identity.')
    account = pwd.getpwuid(uid)
    console = os.stat('/dev/console').st_uid
    if console != uid or account.pw_dir in ('/', '/var/root') or not account.pw_dir.startswith('/Users/'):
        raise ValueError('Only the active local user can apply.')
    raw = base64.b64decode(encoded, validate=True)
    if len(raw) > 4 * 1024 * 1024:
        raise ValueError('Request too large.')
    request = json.loads(raw)
    allowed = {'command', 'dayStart', 'dayEnd', 'sessions', 'revision', 'overrideSourceChanges'}
    if not isinstance(request, dict) or set(request) - allowed or request.get('command') != 'apply':
        raise ValueError('Only a fixed Apply request is accepted.')
    os.initgroups(account.pw_name, account.pw_gid)
    os.setgid(account.pw_gid)
    # Real UID remains the user for ownership checks and pkill. Saved UID is
    # root; only the lexical context below can restore effective root.
    os.setreuid(uid, 0)
    os.seteuid(uid)
    os.environ.clear()
    os.environ.update(HOME=account.pw_dir, USER=account.pw_name, LOGNAME=account.pw_name,
                      PATH='/usr/bin:/bin', LANG='en_US.UTF-8', PYTHONDONTWRITEBYTECODE='1')
    @contextlib.contextmanager
    def system_privileges():
        if os.geteuid() != uid:
            raise RuntimeError('Unexpected nested privilege scope.')
        os.seteuid(0)
        try:
            yield
        finally:
            os.seteuid(uid)
    modules = {}
    for name in ('original_local', 'local_reset', 'backend'):
        module = types.ModuleType('sealed_' + name)
        module.__file__ = '/sealed/' + name + '.py'
        sys.modules[module.__name__] = module
        modules[name] = module
        if name == 'backend':
            module.original_local = modules['original_local']
            module.local_reset = modules['local_reset']
            module.AUTHORIZED_HELPER = True
        exec(compile(sources[name], module.__file__, 'exec'), module.__dict__)
    # User mutation runs in a separate child with root irreversibly discarded.
    # Its inherited plan comes only from the verified in-process transaction,
    # never from a request-supplied command or path.
    writer = modules['original_local'].inject_local
    def user_writer(engine, plan, api):
        read_fd, write_fd = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(read_fd)
            try:
                os.seteuid(0)
                os.setgroups(os.getgrouplist(account.pw_name, account.pw_gid))
                os.setgid(account.pw_gid)
                os.setuid(uid)
                if os.getuid() != uid or os.geteuid() != uid:
                    raise RuntimeError('User writer identity mismatch.')
                try:
                    os.seteuid(0)
                except PermissionError:
                    pass
                else:
                    raise RuntimeError('User writer retained administrator identity.')
                result = writer(engine, plan, api)
                message = dict(result=result)
            except Exception as exc:
                message = dict(error=str(exc), code=getattr(exc, 'code', 'user_write_failed'))
            raw = json.dumps(message).encode()
            if len(raw) > 65536:
                raw = b'{"error":"User writer response exceeds limit."}'
            os.write(write_fd, raw)
            os.close(write_fd)
            os._exit(0)
        os.close(write_fd)
        chunks = []
        total = 0
        while True:
            chunk = os.read(read_fd, 4096)
            if not chunk:
                break
            total += len(chunk)
            if total <= 65536:
                chunks.append(chunk)
        os.close(read_fd)
        _, status = os.waitpid(pid, 0)
        if status != 0 or total > 65536:
            raise RuntimeError('User writer process failed.')
        response = json.loads(b''.join(chunks))
        if 'error' in response:
            raise api.StorageError(response['error'], response.get('code', 'user_write_failed'))
        return response['result']
    modules['original_local'].inject_local = user_writer
    backend = modules['backend']
    reset = modules['local_reset']
    reset.system_privileges = system_privileges
    backend.require(backend.status().get('sip') == 'disabled',
                    'Administrator reset is available only with SIP disabled.', 'reset_unavailable')
    engine = backend.Engine(account.pw_dir)
    # Explicit paths are computed for the original identity, never request input.
    engine.reset_paths = reset.discover(engine, backend)
    result = engine.apply(request)
    print(json.dumps(result, allow_nan=False))
