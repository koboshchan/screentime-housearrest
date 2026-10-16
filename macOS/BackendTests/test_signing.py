"""Signing policy checks never build or modify the installed app."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]

class SigningPolicyTests(unittest.TestCase):
    def test_shell_syntax(self):
        subprocess.run(["bash", "-n", str(ROOT/"build.sh"),
                        str(ROOT/"scripts/signing.sh")], check=True)

    def test_adhoc_refused_before_build(self):
        result = subprocess.run(["bash", str(ROOT/"build.sh")],
                                env=dict(os.environ, SIGN_IDENTITY="-"),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("ad-hoc signing is refused", result.stderr)

    def test_build_preflights_before_compiling_or_replacing_app(self):
        script = (ROOT/"build.sh").read_text()
        check = script.index("bash scripts/signing.sh --check")
        self.assertLess(check, script.index("swift build"))
        self.assertLess(check, script.index('rm -rf "$APP"'))
        self.assertIn('bash scripts/signing.sh --sign "$APP"', script)
