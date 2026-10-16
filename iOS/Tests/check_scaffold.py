import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
count = 0
with tempfile.TemporaryDirectory() as d:
    env = dict(os.environ, JBROOT=d)
    before = list(Path(d).iterdir())
    for args in (["probe"], ["backup"], ["verifyBackup"], ["apply"], [], ["bogus"],
                 ["backup", "00000000-0000-0000-0000-000000000000"], ["probe", "../x"]):
        p = subprocess.run([str(root / "build/helper-host-stub"), *args],
                           capture_output=True, env=env, timeout=5)
        r = json.loads(p.stdout)
        assert p.returncode == 2 and r["ok"] is False
        assert r["code"] == ("integration_unavailable" if len(args) == 1 and args[0] in
                              ("probe", "backup", "verifyBackup", "apply") else "bad_request")
        count += 1
    assert list(Path(d).iterdir()) == before
p = subprocess.run(["python3", str(root / "package.py"), "--production"],
                   capture_output=True, timeout=5)
assert p.returncode == 2 and b"REFUSED" in p.stderr
assert not list((root / "build").glob("*.deb"))
print(f"PASS {count} stub protocol cases; injected environment unused; packaging refused; no .deb")
