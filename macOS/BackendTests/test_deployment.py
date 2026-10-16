import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "verify_deployment", Path(__file__).resolve().parents[1] / "scripts/verify_deployment.py")
deployment = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deployment)

class DeploymentTests(unittest.TestCase):
    def test_expected_build_version(self):
        for platform, minimum in (("IOS", "18.0"), ("MACOS", "26.0")):
            output = f"cmd LC_BUILD_VERSION\n platform {platform}\n minos {minimum}\n sdk 27.2\n"
            with patch.object(deployment.subprocess, "check_output", return_value=output):
                result = deployment.binary(deployment.ROOT / "fixture", platform, minimum)
                self.assertEqual(result["minos"], minimum)

    def test_old_minimum_rejected(self):
        with patch.object(deployment.subprocess, "check_output", return_value=" platform IOS\n minos 15.0\n"):
            with self.assertRaises(ValueError):
                deployment.binary(deployment.ROOT / "fixture", "IOS", "18.0")

    def test_wrong_platform_rejected(self):
        with patch.object(deployment.subprocess, "check_output", return_value=" platform IOSSIMULATOR\n minos 18.0\n"):
            with self.assertRaises(ValueError):
                deployment.binary(deployment.ROOT / "fixture", "IOS", "18.0")

    def test_missing_build_version_rejected(self):
        with patch.object(deployment.subprocess, "check_output", return_value=""):
            with self.assertRaises(ValueError):
                deployment.binary(deployment.ROOT / "fixture", "IOS", "18.0")

    def test_every_architecture_checked(self):
        with patch.object(deployment.subprocess, "check_output", return_value=" platform MACOS\n minos 26.0\n platform MACOS\n minos 14.0\n"):
            with self.assertRaises(ValueError):
                deployment.binary(deployment.ROOT / "fixture", "MACOS", "26.0")

    def test_stale_plist_rejected_before_binary(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(deployment, "ROOT", Path(tmp)):
            info = Path(tmp) / "iOS/build/UNSIGNED-COMPILE-ONLY.app/Info.plist"
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({"MinimumOSVersion": "15.0"}))
            with self.assertRaises(ValueError):
                deployment.verify("ios")
