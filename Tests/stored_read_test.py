#!/usr/bin/env python3
"""Offline checks for lock-free stored reads and the rule that every live reader uses them."""
from pathlib import Path
import re
import sqlite3
import tempfile
import threading
import time
import unittest

import stored_read

ROOT = Path(__file__).resolve().parents[1]


class StoredReadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / 'fixture.cocatalogdb'
        self.writer = sqlite3.connect(self.path, timeout=0, isolation_level=None, check_same_thread=False)
        self.writer.executescript('CREATE TABLE T(V); INSERT INTO T VALUES(1);')

    def tearDown(self):
        self.writer.close()
        self.tmp.cleanup()

    def test_writer_commits_while_a_read_is_open(self):
        def slow(db):
            value = db.execute('SELECT V FROM T').fetchone()[0]
            self.writer.execute('BEGIN IMMEDIATE')
            self.writer.execute('UPDATE T SET V=V+1')
            self.writer.execute('COMMIT')
            return value
        calls = []
        def query(db):
            calls.append(1)
            return slow(db) if len(calls) == 1 else db.execute('SELECT V FROM T').fetchone()[0]
        self.assertEqual(stored_read.read(self.path, query), 2, 'a commit during the read discards it')
        self.assertEqual(len(calls), 2)

    def test_open_save_waits_and_fails_closed(self):
        self.writer.execute('BEGIN IMMEDIATE')
        self.writer.execute('UPDATE T SET V=5')
        self.assertTrue(Path(str(self.path) + '-journal').exists())
        started = time.monotonic()
        with self.assertRaises(TimeoutError):
            stored_read.read(self.path, lambda db: db.execute('SELECT V FROM T').fetchone()[0], seconds=.3)
        self.assertGreaterEqual(time.monotonic() - started, .3)
        threading.Timer(.2, lambda: self.writer.execute('COMMIT')).start()
        self.assertEqual(stored_read.read(self.path, lambda db: db.execute('SELECT V FROM T').fetchone()[0]), 5)

    def test_wal_fails_closed(self):
        self.writer.execute('PRAGMA journal_mode=WAL')
        with self.assertRaises(RuntimeError):
            stored_read.read(self.path, lambda db: 1)

    def test_live_readers_take_no_lock(self):
        offenders = []
        for path in [*ROOT.glob('Tests/*.py'), *ROOT.glob('scripts/*.py'), *ROOT.glob('examples/*.py')]:
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if 'mode=ro' in line and 'immutable=1' not in line:
                    offenders.append(f'{path.relative_to(ROOT)}:{number}')
        self.assertEqual(offenders, [], 'Read a database Capture One may have open with stored_read.read: a locking '
                         'reader across a save makes Capture One drop that save for good (#43).')


if __name__ == '__main__':
    unittest.main()
