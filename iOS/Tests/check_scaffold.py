import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
count = 0
with tempfile.TemporaryDirectory() as directory:
    env = dict(os.environ, JBROOT=directory)
    before = list(Path(directory).iterdir())
    for args in ([], ["probe"], ["backup"], ["verifyBackup"], ["apply"], ["read"],
                 ["bogus"], ["backup", "../x"], ["probe", "unexpected"]):
        result = subprocess.run([str(root / "build/helper-host-stub"), *args],
                                input=b'{"op":"probe"}', capture_output=True,
                                env=env, timeout=5)
        reply = json.loads(result.stdout)
        assert result.returncode == 2 and reply["ok"] is False
        assert reply["code"] == ("auth_unavailable" if not args else "bad_request")
        count += 1
    assert list(Path(directory).iterdir()) == before
for filename in ("Core/NativeStorage.swift", "App/HelperClient.swift"):
    source = (root / filename).read_text()
    gate = "HOST_STORAGE_TEST" if filename.startswith("Core") else "HOST_IPC_TEST"
    assert "#if " + gate in source
request = (root / "Core/Request.swift").read_text()
assert "public var path" not in request and "public var layout" not in request
print(f"PASS {count} fail-closed helper cases; no fixture filesystem access; production request has no paths")
