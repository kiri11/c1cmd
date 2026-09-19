#!/usr/bin/env python3
"""Check the freshness oracle independently of Capture One and its mutation harness."""
import importlib.util
from pathlib import Path
import sqlite3
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('freshness_probe',ROOT/'scripts/probe-catalog-freshness.py')
probe=importlib.util.module_from_spec(spec); spec.loader.exec_module(probe)


class FreshnessProbeTests(unittest.TestCase):
    def test_observer_uses_fresh_transactions_and_committed_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'fixture.cocatalogdb'
            db=sqlite3.connect(path)
            try:
                db.executescript('''
                    CREATE TABLE ZVARIANT(Z_PK, ZVARIANTUUID, ZCOMBINEDSETTINGS);
                    CREATE TABLE ZVARIANTLAYER(Z_PK, ZMETADATA, ZEXPOSURE, ZCONTRAST, ZSATURATION, ZWHITEBALANCE, ZROTATION, ZCROP);
                    CREATE TABLE ZVARIANTMETADATA(Z_PK, ZBASIC_RATING, ZCOLOR_TAG_INDEX);
                    INSERT INTO ZVARIANT VALUES(1,'uuid',1);
                    INSERT INTO ZVARIANTLAYER VALUES(1,1,0,0,0,'raw-wb',0,'raw-crop');
                    INSERT INTO ZVARIANTMETADATA VALUES(1,0,0);
                ''')
                self.assertTrue(probe.matches(probe.snapshot(path)[0],dict(rating=0,exposure=0)))
                db.execute('UPDATE ZVARIANTMETADATA SET ZBASIC_RATING=4')
                self.assertFalse(probe.matches(probe.snapshot(path)[0],dict(rating=4)))
                db.commit()
                self.assertTrue(probe.matches(probe.snapshot(path)[0],dict(rating=4)))
                # A completed observation cannot hold a read transaction blocking writes.
                db.execute('BEGIN EXCLUSIVE'); db.rollback()
            finally: db.close()

    def test_incomplete_or_different_state_is_not_convergence(self):
        self.assertFalse(probe.matches(None,dict(rating=4)))
        self.assertFalse(probe.matches({},dict(rating=4)))
        self.assertFalse(probe.matches(dict(rating=4,colorTag=2),dict(rating=4,colorTag=3)))
        self.assertFalse(probe.matches(dict(exposure=float('nan')),dict(exposure=.25)))
        self.assertTrue(probe.matches(dict(exposure=.25000001),dict(exposure=.25)))

    def test_fixture_guards_fail_closed(self):
        with self.assertRaises(RuntimeError): probe.require(False,'not the owned fixture')
        probe.require(True,'owned')


if __name__=='__main__': unittest.main()
