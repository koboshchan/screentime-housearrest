"""Restored writer integration tests use isolated synthetic stores only."""
import os
from pathlib import Path
import sqlite3
import unittest
from unittest.mock import patch
import test_backend
b=test_backend.b

class OriginalTests(unittest.TestCase):
    setUp=test_backend.Tests.setUp
    def setUp(self):
        test_backend.Tests.setUp(self)
        with sqlite3.connect(self.engine.database) as conn:
            for name in ('Z_ENT','Z_OPT','ZCREATIONDATE'):
                conn.execute('ALTER TABLE ZOBJECT ADD COLUMN '+name+' INTEGER')
        # The original writer edits only the latest segment; place a complete
        # pair there and retain an empty older segment.
        (self.engine.stream/'a').write_bytes(test_backend.segment([]))
        (self.engine.stream/'b').write_bytes(test_backend.segment([(True,100,'com.test.App'),(False,200,'com.test.App')]))
        self.addCleanup(self.unseal)
    def unseal(self):
        for root,dirs,files in os.walk(self.tmp.name):
            os.chmod(root,0o700)
    def request(self):
        return dict(revision=self.engine.read()['revision'],dayStart=0,dayEnd=86400,
                    sessions=[dict(id='new',bundle='com.new.App',start=300,end=400)])
    def test_restored_apply_with_verified_backup(self):
        result=self.engine.apply(self.request())
        self.assertEqual(result['status'],'SUCCESS_LOGOUT_REQUIRED')
        self.assertTrue(result['logoutRequired'])
        b.verify_backup(Path(result['backupPath']))
        self.assertEqual([(s['bundle'],s['start'],s['end']) for s in self.engine.read()['sessions']],[('com.new.App',300,400)])
        with sqlite3.connect(self.engine.database) as conn:
            self.assertEqual(conn.execute("SELECT ZVALUESTRING,Z_ENT,Z_OPT FROM ZOBJECT WHERE ZSTREAMNAME='/app/usage'").fetchall(),[('com.new.App',1,1)])
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM ZOBJECT WHERE ZSTREAMNAME='/other'").fetchone()[0],1)
    def test_backup_failure_writer_never_called(self):
        request=self.request(); before=self.engine.fingerprint()
        with patch.object(b,'verified_backup',side_effect=b.StorageError('backup failure')), patch.object(b.original_local,'inject_local') as writer:
            with self.assertRaisesRegex(b.StorageError,'backup failure'): self.engine.apply(request)
            writer.assert_not_called()
        self.assertEqual(before,self.engine.fingerprint())
    def test_independent_verification_failure_writer_never_called(self):
        request=self.request()
        with patch.object(b,'verify_backup',side_effect=b.StorageError('independent verify failed')), patch.object(b.original_local,'inject_local') as writer:
            with self.assertRaisesRegex(b.StorageError,'independent verify'): self.engine.apply(request)
            writer.assert_not_called()
    def test_stale_never_calls_writer(self):
        request=self.request();request['revision']='0'*64
        with patch.object(b.original_local,'inject_local') as writer:
            with self.assertRaisesRegex(b.StorageError,'changed since'): self.engine.apply(request)
            writer.assert_not_called()
    def test_preflight_capacity_no_backup_no_writes(self):
        request=self.request()
        request['sessions']=[dict(id=str(i),bundle='x'*4000,start=i*2,end=i*2+1) for i in range(5)]
        before=self.engine.fingerprint()
        with patch.object(b,'verified_backup') as backup,patch.object(b.original_local,'inject_local') as writer:
            with self.assertRaisesRegex(b.StorageError,'capacity'):self.engine.apply(request)
            backup.assert_not_called();writer.assert_not_called()
        self.assertEqual(before,self.engine.fingerprint())
    def test_crossing_day_preserved_both_stores(self):
        request=self.request();request.update(dayStart=120,dayEnd=180,sessions=[dict(id='n',bundle='new',start=130,end=160)])
        self.engine.apply(request)
        self.assertEqual(sorted((s['bundle'],s['start'],s['end']) for s in self.engine.read()['sessions']),[('com.test.App',100,120),('com.test.App',180,200),('new',130,160)])
        with sqlite3.connect(self.engine.database) as conn:
            self.assertEqual(conn.execute("SELECT ZSTARTDATE,ZENDDATE FROM ZOBJECT WHERE ZSTREAMNAME='/app/usage' ORDER BY ZSTARTDATE").fetchall(),[(100,120),(130,160),(180,200)])
    def test_second_store_failure_reports_backup(self):
        with patch.object(b.original_local,'inject_local',side_effect=sqlite3.OperationalError('fixture failure')):
            with self.assertRaisesRegex(b.StorageError,'partially changed.*Verified backup:'): self.engine.apply(self.request())
    def test_long_bundle_valid_varint(self):
        request=self.request();request['sessions'][0]['bundle']='x'*300
        self.engine.apply(request)
        self.assertEqual(self.engine.read()['sessions'][0]['bundle'],'x'*300)
    def test_module_import_no_side_effect(self):
        source=Path(b.original_local.__file__).read_text()
        self.assertNotIn('killall',source);self.assertNotIn('launchctl',source)
        self.assertNotIn('/Users/',source)

if __name__=='__main__':unittest.main()
