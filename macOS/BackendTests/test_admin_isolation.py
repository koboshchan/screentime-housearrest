import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

class IsolationTests(unittest.TestCase):
    def test_pythonpath_cwd_and_sitecustomize_cannot_inject(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            marker=root/'INJECTED'
            evil="from pathlib import Path\nPath("+repr(str(marker))+").write_text('injected')\n"
            for name in ('json.py','sitecustomize.py','usercustomize.py'):
                (root/name).write_text(evil)
            env=dict(os.environ,PYTHONPATH=directory,PYTHONHOME='/invalid/injected')
            result=subprocess.run([sys.executable,'-I','-S','-B','-c',
                "import json,sys; assert sys.flags.isolated; assert sys.flags.no_site; assert '' not in sys.path; print(json.dumps({'isolated': True}))"],
                cwd=directory,env=env,text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('"isolated": true',result.stdout)
            self.assertFalse(marker.exists())
    def test_native_bootstrap_irreversible_user_writer(self):
        root=Path(__file__).resolve().parents[1]
        source=(root/'Sources/AdminHelper/admin_entry.py').read_text()
        self.assertIn('os.fork()',source)
        self.assertIn('os.setgroups(os.getgrouplist(',source)
        self.assertIn('os.setgid(account.pw_gid)',source)
        self.assertIn('os.setuid(uid)',source)
        self.assertIn('User writer retained administrator identity.',source)
