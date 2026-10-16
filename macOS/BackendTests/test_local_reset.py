"""All reset operations target temporary fixtures and fake process runners."""
import json
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import test_original_local
import test_backend
b=test_backend.b
r=b.local_reset

class ResetTests(test_original_local.OriginalTests):
    def setUp(self):
        super().setUp()
        self.engine.status_provider=lambda:dict(sip='disabled')
        self.light=Path(self.tmp.name)/'system/backlight'
        self.light.mkdir(parents=True)
        # arbitrary names; newest header creation chooses latest, not numeric name
        (self.light/'strange-name').write_bytes(test_backend.segment([]))
        self.cache=Path(self.tmp.name)/'darwin/agent/Local'
        (self.cache/'nested/empty').mkdir(parents=True)
        (self.cache/'nested/blob').write_bytes(b'private cache')
        self.engine.reset_paths=(self.light,self.cache)
        self.calls=[]
        def run(args,**kwargs):
            self.calls.append(args)
            return SimpleNamespace(returncode=0,stderr='',stdout='')
        self.engine.reset_runner=run
        self.engine.reset_access=lambda *args:True
        with b.sqlite3.connect(self.engine.database) as c:
            c.execute('ALTER TABLE ZOBJECT ADD COLUMN ZVALUEINTEGER INTEGER')
    # Inherited local writer tests deliberately remain SIP-enabled fixture cases.
    def request(self):
        return super().request()
    def test_sip_off_reset_and_both_snapshots(self):
        result=self.engine.apply(self.request())
        self.assertFalse(result['logoutRequired'])
        self.assertEqual(result['status'],'SUCCESS_RESET_COMPLETED')
        self.assertFalse(self.cache.exists())
        self.assertEqual(len(self.calls),5)
        self.assertIn('gui/'+str(os.getuid())+'/com.apple.UsageTrackingAgent',self.calls[-1])
        backup=Path(result['resetBackupPath'])
        manifest=json.loads((backup/'manifest.json').read_text())
        self.assertTrue(manifest['cacheExists'])
        self.assertEqual(len(manifest['directories']),3)
        b.verify_backup(Path(result['backupPath']))
        with b.sqlite3.connect(self.engine.database) as c:
            self.assertEqual(c.execute("SELECT ZVALUEINTEGER FROM ZOBJECT WHERE ZSTREAMNAME='/display/isBacklit'").fetchall(),[(1,)])
    def test_enabled_and_unknown_never_reset(self):
        for sip in ('enabled','unknown'):
            self.engine.status_provider=lambda:dict(sip=sip)
            with patch.object(r,'prepare') as prepare:
                result=self.engine.apply(self.request())
                self.assertTrue(result['logoutRequired'])
                prepare.assert_not_called()
            self.assertTrue(self.cache.exists())
        self.assertFalse(self.calls)
    def test_permission_denial_retains_backup_no_writer(self):
        request=self.request()
        self.engine.reset_access=lambda *args:False
        before=self.engine.fingerprint()
        with patch.object(b.original_local,'inject_local') as writer:
            with self.assertRaisesRegex(b.StorageError,'Verified usage backup:') as error:
                self.engine.apply(request)
            self.assertEqual(error.exception.code,'permission_denied')
            writer.assert_not_called()
        self.assertFalse(self.calls)
        self.assertEqual(self.engine.fingerprint(),before)
        self.assertTrue(self.cache.exists())
    def test_reset_verification_failure_no_writer(self):
        with patch.object(r,'verify',side_effect=b.StorageError('bad reset backup')),patch.object(b.original_local,'inject_local') as writer:
            with self.assertRaisesRegex(b.StorageError,'no stores changed'):self.engine.apply(self.request())
            writer.assert_not_called()
        self.assertFalse(self.calls)
    def test_changed_reset_source_no_writer(self):
        real=r.snapshot
        def change(plan,dest,api):
            result=real(plan,dest,api)
            (self.cache/'new').write_bytes(b'new')
            return result
        with patch.object(r,'snapshot',side_effect=change),patch.object(b.original_local,'inject_local') as writer:
            with self.assertRaisesRegex(b.StorageError,'changed after backup'):self.engine.apply(self.request())
            writer.assert_not_called()
    def test_cache_symlink_rejected(self):
        (self.cache/'link').symlink_to(self.engine.database)
        with patch.object(b.original_local,'inject_local') as writer:
            with self.assertRaisesRegex(b.StorageError,'symlink'):self.engine.apply(self.request())
            writer.assert_not_called()
    def test_override_uses_current_usage_and_reset_snapshots(self):
        request=self.request()
        request.update(revision='0'*64,overrideSourceChanges=True)
        current=self.engine.fingerprint()
        result=self.engine.apply(request)
        b.verify_backup(Path(result['backupPath']),current)
        self.assertTrue(Path(result['resetBackupPath']).exists())
    def test_all_backlight_segments_backed_up(self):
        (self.light/'not-a-number').write_bytes(test_backend.segment([]))
        result=self.engine.apply(self.request())
        state=json.loads((Path(result['resetBackupPath'])/'manifest.json').read_text())
        self.assertEqual(len([k for k in state['files'] if k.startswith('backlight/')]),2)
    def test_reset_snapshot_failure_never_calls_writer(self):
        with patch.object(r,'snapshot',side_effect=PermissionError('denied')),patch.object(b.original_local,'inject_local') as writer:
            with self.assertRaisesRegex(b.StorageError,'no stores changed.*Verified usage backup:'):
                self.engine.apply(self.request())
            writer.assert_not_called()
        self.assertFalse(self.calls)
    def test_no_matching_process_is_not_a_failure(self):
        def run(args,**kwargs):
            return SimpleNamespace(returncode=1 if args[0]=='/usr/bin/pkill' else 0,stderr='')
        self.engine.reset_runner=run
        self.assertFalse(self.engine.apply(self.request())['logoutRequired'])
    def test_cache_absence_is_recorded(self):
        import shutil
        shutil.rmtree(self.cache)
        result=self.engine.apply(self.request())
        manifest=json.loads((Path(result['resetBackupPath'])/'manifest.json').read_text())
        self.assertFalse(manifest['cacheExists'])
    def test_process_denial_is_failure_not_success(self):
        self.engine.reset_runner=lambda *a,**kw:SimpleNamespace(returncode=1,stderr='Operation not permitted')
        with patch.object(b.original_local,'inject_local') as writer:
            with self.assertRaisesRegex(b.StorageError,'partially changed.*Verified backup:'):self.engine.apply(self.request())
            writer.assert_not_called()
    def test_restart_denial_reports_partial_with_both_backups(self):
        def run(args,**kwargs):
            return SimpleNamespace(returncode=5 if args[0]=='/bin/launchctl' else 0,stderr='denied' if args[0]=='/bin/launchctl' else '')
        self.engine.reset_runner=run
        with self.assertRaisesRegex(b.StorageError,'Reset backup:.*reset.*restart failed'):self.engine.apply(self.request())
    def test_sealed_reset_byte_tamper_rejected(self):
        plan=r.prepare(self.engine,0,86400,[],b,self.engine.reset_paths)
        dest=Path(self.tmp.name)/'snapshot'
        r.snapshot(plan,dest,b)
        file=next(dest.glob('file-*'))
        os.chmod(file,0o600);file.write_bytes(b'bad');os.chmod(file,0o400)
        with self.assertRaisesRegex(b.StorageError,'bytes mismatch'):r.verify(dest,plan,b)

# Reuse only fixture setup/helpers, not the base local-only expectations.
for name in list(test_original_local.OriginalTests.__dict__):
    if name.startswith('test_') and name not in ResetTests.__dict__:
        setattr(ResetTests,name,None)

if __name__=='__main__':unittest.main()
