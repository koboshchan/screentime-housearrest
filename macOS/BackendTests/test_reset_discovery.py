"""Discovery regression tests. No live paths read or written."""
import os
from pathlib import Path
from types import SimpleNamespace
import subprocess
import unittest
from unittest.mock import patch
import test_backend
r = test_backend.b.local_reset

class DiscoveryError(Exception):
    def __init__(self, message, code):
        super().__init__(message)
        self.code = code

class API:
    @staticmethod
    def require(condition, message, code):
        if not condition:
            raise DiscoveryError(message, code)

class DiscoveryTests(unittest.TestCase):
    def result(self, stdout='/var/folders/fixture/current-user/0/\n', stderr='', code=0):
        return SimpleNamespace(stdout=stdout, stderr=stderr, returncode=code)

    def test_native_getconf_not_unrecognized_python_key(self):
        # Reproduce Apple's Python builds which omit this Darwin extension.
        with patch.object(os, 'confstr', side_effect=ValueError('unrecognized configuration name')) as confstr, patch.object(r.subprocess, 'run', return_value=self.result()) as run:
            backlight, cache = r.discover(None, API)
        confstr.assert_not_called()
        run.assert_called_once_with(['/usr/bin/getconf', 'DARWIN_USER_DIR'],
            capture_output=True, text=True, timeout=10, check=False)
        self.assertEqual(backlight, Path('/private/var/db/biome/streams/restricted/Device.Display.Backlight/local'))
        self.assertEqual(cache, Path('/var/folders/fixture/current-user/0').resolve() / 'com.apple.ScreenTimeAgent/Store/Library/com.apple.DeviceActivity/Local')

    def test_missing_key_fails_closed(self):
        self.assert_invalid(self.result(code=1))

    def test_empty_result_never_uses_working_directory(self):
        self.assert_invalid(self.result(stdout='\n'))

    def test_relative_result_refused(self):
        self.assert_invalid(self.result(stdout='relative/path\n'))

    def test_root_refused(self):
        self.assert_invalid(self.result(stdout='/\n'))

    def test_multiline_result_refused(self):
        self.assert_invalid(self.result(stdout='/var/folders/user/0\n/other/user/0\n'))

    def test_nul_result_refused(self):
        self.assert_invalid(self.result(stdout='/var/folders/\0user'))

    def test_stderr_refused(self):
        self.assert_invalid(self.result(stderr='getconf failed'))

    def test_missing_utility_and_timeout_fail_closed(self):
        for error in (FileNotFoundError('missing'), subprocess.TimeoutExpired('getconf', 10)):
            with self.subTest(error=type(error).__name__), patch.object(r.subprocess, 'run', side_effect=error):
                with self.assertRaises(DiscoveryError) as failure:
                    r.discover(None, API)
                self.assertEqual(failure.exception.code, 'reset_unavailable')

    def assert_invalid(self, result):
        with patch.object(r.subprocess, 'run', return_value=result):
            with self.assertRaises(DiscoveryError) as failure:
                r.discover(None, API)
        self.assertEqual(failure.exception.code, 'reset_unavailable')

if __name__ == '__main__':
    unittest.main()
