"""Guard the refresh-only transport against jailbreak path and shell regressions."""
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
class RefreshChecks(unittest.TestCase):
    def test_native_fixed_refresh(self):
        route = (ROOT/'iOS/Core/GeminiIOSRoute.swift').read_text().split('extension NativeStorage')[0]
        self.assertIn('NativeStorage.refreshProcesses(refreshTargets)', route)
        for name in ['Preferences', 'ScreenTimeSettingsAgent', 'ScreenTimeAgent', 'UsageTrackingAgent', 'biomed']:
            self.assertIn('"'+name+'"', route)
        self.assertNotIn('posix_spawn', route)
        self.assertNotIn('/usr/bin/', route.split('static let refreshTargets')[1])
    def test_open_only_after_success(self):
        store = (ROOT/'iOS/App/Store.swift').read_text()
        success = store.split('if a.ok {')[1].split('} else if')[0]
        self.assertIn('UIApplication.shared.open(url)', success)
        self.assertIn('#if os(iOS)', success)
    def test_no_new_cache_deletions(self):
        route = (ROOT/'iOS/Core/GeminiIOSRoute.swift').read_text()
        refresh = route.split('static func refresh()')[1].split('extension NativeStorage')[0]
        self.assertNotIn('removeItem', refresh)
        self.assertIn('try verifyBackup(id,expected:before)', route)
if __name__ == '__main__':
    unittest.main()
