"""Fixture-only proof that both sealed backups precede stop and either writer."""
from unittest.mock import patch
import test_backend
import test_local_reset
b=test_backend.b
r=b.local_reset

class BackupOrderingTests(test_local_reset.ResetTests):
    def test_backups_and_final_revision_precede_stop_and_writers(self):
        events=[]
        def wrapped(name,fn):
            def run(*a,**kw):
                result=fn(*a,**kw)
                events.append(name)
                return result
            return run
        with patch.object(b,'verify_backup',side_effect=wrapped('usage-verified',b.verify_backup)),patch.object(r,'verify',side_effect=wrapped('reset-verified',r.verify)),patch.object(r,'preflight',side_effect=wrapped('preflight',r.preflight)),patch.object(r,'stop_processes',side_effect=wrapped('stop',r.stop_processes)),patch.object(b.original_local,'inject_local',side_effect=wrapped('userwrite',b.original_local.inject_local)),patch.object(r,'perform',side_effect=wrapped('rootreset',r.perform)):
            self.engine.apply(self.request())
        stop=events.index('stop')
        self.assertIn('usage-verified',events[:stop])
        self.assertIn('reset-verified',events[:stop])
        self.assertIn('preflight',events[:stop])
        self.assertLess(stop,events.index('userwrite'))
        self.assertLess(events.index('userwrite'),events.index('rootreset'))
    def test_failed_system_backup_no_stop_or_usagewrite(self):
        with patch.object(r,'snapshot',side_effect=b.StorageError('fixturefail')),patch.object(r,'stop_processes') as stop,patch.object(b.original_local,'inject_local') as userwrite,patch.object(r,'perform') as reset:
            with self.assertRaises(b.StorageError):self.engine.apply(self.request())
            stop.assert_not_called();userwrite.assert_not_called();reset.assert_not_called()
    def test_late_revision_change_after_both_backups_no_writes(self):
        original=r.preflight
        def change(*args,**kwargs):
            original(*args,**kwargs)
            # A concurrent app segment update is detected by final fingerprint.
            segment=self.engine.source_paths()[0]
            raw=bytearray(segment.read_bytes());raw[-1]^=1;segment.write_bytes(raw)
        with patch.object(r,'preflight',side_effect=change),patch.object(r,'stop_processes') as stop,patch.object(b.original_local,'inject_local') as userwrite,patch.object(r,'perform') as reset:
            with self.assertRaises(b.StorageError):self.engine.apply(self.request())
            stop.assert_not_called();userwrite.assert_not_called();reset.assert_not_called()

# Do not count inherited tests again.
for name in dir(test_local_reset.ResetTests):
    if name.startswith('test_') and name not in BackupOrderingTests.__dict__:
        setattr(BackupOrderingTests,name,None)
