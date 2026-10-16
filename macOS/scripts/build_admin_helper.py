#!/usr/bin/env python3
"""Embed audited Python as immutable data in a signed native executable."""
from pathlib import Path
import base64
import json
root = Path(__file__).resolve().parents[1]
resources = root/'Sources/ScreenTimeEditor/Resources'
sources = {name:(resources/(name+'.py')).read_text() for name in ('original_local','local_reset','backend')}
# Strip disk imports structurally by exact known delimiters, failing closed.
backend = sources['backend']
start = backend.index('_MODULE_PATH = ')
end = backend.index('\nclass StorageError', start)
sources['backend'] = backend[:start] + 'AUTHORIZED_HELPER = True\n' + backend[end:]
# Never invoke the CLI or disk helper inside the embedded interpreter.
sources['backend'] = sources['backend'].replace('if __name__ == "__main__":', 'if False:')
entry = (root/'Sources/AdminHelper/admin_entry.py').read_text()
payload = ("import sys, os\n"
           "if not sys.flags.isolated or not sys.flags.no_site or '' in sys.path:\n"
           "    raise RuntimeError('Isolated system interpreter is required.')\n"
           "if any(k.startswith('PYTHON') for k in os.environ):\n"
           "    raise RuntimeError('Python environment injection refused.')\n"
           "sources = " + repr(sources) + '\n' + entry + '\n')
payload += """try:
    entry(sources, sys.argv[1], sys.argv[2])
except Exception as exc:
    print(json.dumps(dict(error=str(exc), code=getattr(exc, 'code', 'admin_apply_failed'))))
    sys.exit(1)
"""
encoded = base64.b64encode(payload.encode()).decode()
out = root/'.build/admin-helper'
out.mkdir(parents=True, exist_ok=True)
# -I ignores user site, PYTHONPATH and working directory, -S disables site.
# Only fixed system interpreter + immutable signed embedded source are executed.
swift = '''
import Foundation
import Darwin
let args = CommandLine.arguments
guard args.count == 3, args[1].count <= 6_000_000,
      args[1].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [43,47,61].contains($0) }),
      args[2].utf8.allSatisfy({ (48...57).contains($0) }), args[2].count <= 10 else {
  fputs("Invalid fixed Apply request.\\n", stderr); exit(2)
}
guard geteuid() == 0 else {
  fputs("Native administrator authorization required.\\n", stderr); exit(2)
}
let bootstrap = "import base64;exec(compile(base64.b64decode(EMBEDDED),'<signed-admin-helper>','exec'))"
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
p.arguments = ["-I", "-S", "-B", "-c", bootstrap, args[1], args[2]]
p.environment = ["PATH":"/usr/bin:/bin", "LANG":"en_US.UTF-8", "HOME":"/var/empty"]
p.currentDirectoryURL = URL(fileURLWithPath: "/var/empty")
p.standardOutput = FileHandle.standardOutput
p.standardError = FileHandle.standardError
p.standardInput = FileHandle.nullDevice
do { try p.run(); p.waitUntilExit(); exit(p.terminationStatus) }
catch { fputs("Could not start fixed isolated backend.\\n", stderr); exit(2) }
'''.replace('EMBEDDED', repr(encoded))
# Swift bootstrap is a quoted string; insert as Swift JSON string literal.
a=swift.index('let bootstrap = ')
z=swift.index('\nlet p =',a)
bootstrap="import base64;exec(compile(base64.b64decode("+repr(encoded)+"),'<signed-admin-helper>','exec'))"
swift=swift[:a]+'let bootstrap = '+json.dumps(bootstrap)+swift[z:]
(out/'main.swift').write_text(swift)
print(out/'main.swift')
