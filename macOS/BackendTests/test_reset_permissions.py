"""Read/privilege denials fail before connecting to or modifying usage stores."""
import errno
from pathlib import Path
import unittest
from unittest.mock import Mock, patch
import test_backend
b = test_backend.b
r = b.local_reset

class ResetPermissionTests(unittest.TestCase):
    def test_system_store_denial_explains_privileges_without_writes(self):
        engine = Mock()
        error = PermissionError(errno.EACCES, 'Permission denied',
                                '/private/var/db/biome/streams/restricted')
        with patch.object(r, 'discover', return_value=(
                Path('/private/var/db/biome/streams/restricted/Device.Display.Backlight/local'),
                Path('/var/folders/fixture/Local'))), patch.object(r, 'inventory', side_effect=error):
            with self.assertRaises(b.StorageError) as failure:
                r.prepare(engine, 0, 86400, [], b)
        self.assertEqual(failure.exception.code, 'system_store_permission_denied')
        self.assertIn('Full Disk Access may already be enabled', str(failure.exception))
        self.assertIn('No Screen Time stores were changed', str(failure.exception))
        engine.open_database.assert_not_called()

    def test_user_cache_denial_offers_fda_without_writes(self):
        engine = Mock()
        error = PermissionError(errno.EPERM, 'Operation not permitted', '/var/folders/fixture/Local')
        with patch.object(r, 'inventory', side_effect=error):
            with self.assertRaises(b.StorageError) as failure:
                r.prepare(engine, 0, 86400, [], b, (
                    Path('/system/backlight'), Path('/var/folders/fixture/Local')))
        self.assertEqual(failure.exception.code, 'permission_denied')
        self.assertIn('Full Disk Access', str(failure.exception))
        engine.open_database.assert_not_called()
