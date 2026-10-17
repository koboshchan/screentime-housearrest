"""Presentation-only regression guards, no device access or usage writes."""
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]

class PresentationContract(unittest.TestCase):
    def test_status_uses_capability(self):
        self.assertIn('available ? "Live access ready"', (ROOT/'iOS/App/AccessStatusView.swift').read_text())
        self.assertIn('available: store.capability.canApply', (ROOT/'iOS/App/ContentView.swift').read_text())
    def test_visible_timeline(self):
        ui = (ROOT/'iOS/App/ContentView.swift').read_text()
        self.assertIn('height: 36', ui)
        self.assertIn('ScrollView([.horizontal, .vertical])', ui)
        self.assertIn('AppIdentity.shared.name(s.bundleID)', ui)
    def test_search_both_fields(self):
        for path in ['iOS/App/AppIdentity.swift', 'macOS/Sources/ScreenTimeEditor/AppIdentity.swift']:
            ui = (ROOT/path).read_text()
            self.assertGreaterEqual(ui.count('localizedCaseInsensitiveContains(query)'), 2)
            self.assertIn('selection = id', ui)
            self.assertIn('Text(id)', ui)
    def test_picker_replaces_add_field(self):
        ios = (ROOT/'iOS/App/ContentView.swift').read_text()
        mac = (ROOT/'macOS/Sources/ScreenTimeEditor/SessionList.swift').read_text().split('struct AddSheet')[1]
        for ui in [ios, mac]:
            self.assertIn('InstalledAppPicker(selection:', ui)
            self.assertIn('showingPicker = true', ui)
        self.assertNotIn('TextField("App bundle ID"', mac)
    def test_readonly_catalog(self):
        for path in ['iOS/App/AppIdentity.swift', 'macOS/Sources/ScreenTimeEditor/AppIdentity.swift']:
            ui = (ROOT/path).read_text()
            self.assertNotIn('HelperClient', ui)
            self.assertNotIn('.apply(', ui)
            self.assertNotIn('write(to:', ui)

if __name__ == '__main__':
    unittest.main()
