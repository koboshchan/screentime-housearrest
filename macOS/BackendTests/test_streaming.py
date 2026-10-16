"""Fixture-only tests. Never opens the current user's live Screen Time stores."""
import hashlib
import os
from pathlib import Path
import sqlite3
import tracemalloc
import unittest
from unittest.mock import patch
import test_backend
b = test_backend.b

class StreamingTests(unittest.TestCase):
    setUp = test_backend.Tests.setUp

    def sparse(self, name='large'):
        path = Path(self.tmp.name) / name
        with path.open('wb') as handle:
            handle.seek(b.MAX_SEGMENT + 8191)
            handle.write(b'x')
        return path

    def test_large_sparse_hash_bounded(self):
        path = self.sparse()
        tracemalloc.start()
        try:
            size, digest = b.file_digest(path)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertEqual(size, b.MAX_SEGMENT + 8192)
        self.assertEqual(len(digest), 64)
        self.assertLess(peak, 4 * b.STREAM_CHUNK)
        with self.assertRaisesRegex(b.StorageError, 'size'): b.checked_bytes(path)

    def test_large_private_copy(self):
        source = self.sparse()
        target = Path(self.tmp.name)/'copy'
        self.assertEqual(b.copy_private(source,target), b.file_digest(source))
        self.assertEqual(b.file_digest(target), b.file_digest(source))
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)

    def test_large_sparse_db_and_wal_fingerprint(self):
        # SQLite ignores trailing unallocated pages; keep the fixture sparse.
        with self.engine.database.open('ab') as handle:
            handle.truncate(b.MAX_SEGMENT + 8192)
        wal = Path(str(self.engine.database)+'-wal')
        self.sparse('wal-source').rename(wal)
        revision = self.engine.fingerprint()
        self.assertEqual(len(revision),64)
        with wal.open('r+b') as handle:
            handle.seek(b.MAX_SEGMENT + 1); handle.write(b'changed')
        self.assertNotEqual(revision,self.engine.fingerprint())
        wal.unlink()
        self.assertEqual(len(self.engine.read()['sessions']),1)

    def test_large_valid_sqlite_backup_verify_and_corruption(self):
        with sqlite3.connect(self.engine.database) as conn:
            conn.execute('CREATE TABLE padding (data BLOB)')
            conn.execute('INSERT INTO padding VALUES (zeroblob(?))',(b.MAX_SEGMENT+8192,))
        dest = Path(self.tmp.name)/'large-backup'
        manifest = b.verified_backup(self.engine,dest)
        self.addCleanup(lambda: dest.chmod(0o700))
        self.assertGreater(manifest['files']['knowledgeC.db']['size'],b.MAX_SEGMENT)
        self.assertEqual(b.verify_backup(dest),manifest)
        target=dest/'knowledgeC.db'; target.chmod(0o600)
        with target.open('r+b') as handle:
            handle.seek(b.MAX_SEGMENT+1); handle.write(b'corrupt')
        target.chmod(0o400)
        with self.assertRaisesRegex(b.StorageError,'digest'): b.verify_backup(dest)

    def test_large_real_wal_read(self):
        conn = sqlite3.connect(self.engine.database)
        self.addCleanup(conn.close)
        conn.execute('PRAGMA journal_mode=WAL')
        conn.execute('PRAGMA wal_autocheckpoint=0')
        conn.execute('CREATE TABLE padding (data BLOB)')
        conn.execute('INSERT INTO padding VALUES (zeroblob(?))',(b.MAX_SEGMENT+8192,))
        conn.commit()
        self.assertGreater(Path(str(self.engine.database)+'-wal').stat().st_size,b.MAX_SEGMENT)
        self.assertEqual(len(self.engine.read()['sessions']),1)

    def test_same_size_mutation_rejected(self):
        path=self.sparse()
        def consume(chunk):
            with path.open('r+b') as handle: handle.write(b'z')
        with self.assertRaisesRegex(b.StorageError,'changed'): b.scan_file(path,consume)

    def test_growth_and_truncation_rejected(self):
        for grow in (True,False):
            with self.subTest(grow=grow):
                path=self.sparse('grow'+str(grow)); changed=[False]
                def consume(chunk):
                    if not changed[0]:
                        changed[0]=True
                        with path.open('r+b') as handle:
                            handle.truncate(path.stat().st_size+1 if grow else 1)
                with self.assertRaises(b.StorageError) as caught: b.scan_file(path,consume)
                self.assertEqual(caught.exception.code,'concurrent_change')

    def test_path_replacement_and_symlink_during_scan(self):
        for symlink in (False,True):
            with self.subTest(symlink=symlink):
                path=self.sparse('replace'+str(symlink)); changed=[False]
                def consume(chunk):
                    if not changed[0]:
                        changed[0]=True
                        moved=path.with_name(path.name+'-original'); path.rename(moved)
                        if symlink: path.symlink_to(moved)
                        else: path.write_bytes(b'replacement')
                with self.assertRaises(b.StorageError): b.scan_file(path,consume)

    def test_descriptor_swap_before_open(self):
        path=self.sparse(); original=b.os.open
        def swap(name,flags,*args):
            if str(name)==str(path):
                path.rename(path.with_name('old')); path.write_bytes(b'new')
            return original(name,flags,*args)
        with patch.object(b.os,'open',side_effect=swap):
            with self.assertRaisesRegex(b.StorageError,'replaced'): b.file_digest(path)

    def test_symlink_and_nonregular_refused(self):
        path=self.sparse(); alias=path.with_name('alias'); alias.symlink_to(path)
        with self.assertRaises(b.StorageError): b.file_digest(alias)
        fifo=path.with_name('fifo'); os.mkfifo(fifo)
        with self.assertRaises(b.StorageError): b.file_digest(fifo)

if __name__=='__main__': unittest.main()
