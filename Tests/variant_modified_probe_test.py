#!/usr/bin/env python3
"""Check the variant-modified probe's stored reads and verdicts without Capture One."""
import importlib.util
from pathlib import Path
import sqlite3
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('variant_modified_probe', ROOT / 'scripts/probe-variant-modified.py')
probe = importlib.util.module_from_spec(spec); spec.loader.exec_module(probe)

SCHEMA = '''
    CREATE TABLE ZIMAGE(Z_PK INTEGER PRIMARY KEY, ZIMAGEFILENAME, ZSETTINGSMODIFICATIONDATE);
    CREATE TABLE ZVARIANT(Z_PK INTEGER PRIMARY KEY, ZIMAGE, ZISMODIFIED, ZDEFAULTLAYER, ZCOMBINEDSETTINGS, ZADJUSTMENTLAYER);
    CREATE TABLE ZVARIANTLAYER(Z_PK INTEGER PRIMARY KEY, Z_ENT, ZINDEX, ZVARIANT, ZMETADATA, ZEXPOSURE, ZROTATION);
    CREATE TABLE ZVARIANTMETADATA(Z_PK INTEGER PRIMARY KEY, ZLAYER, ZBASIC_RATING, ZCOLOR_TAG_INDEX);
    INSERT INTO ZIMAGE VALUES(1,'tonal.CR3',0),(2,'other.CR3',0);
    INSERT INTO ZVARIANT VALUES(1,1,0,10,11,NULL),(2,2,1,20,21,NULL);
    INSERT INTO ZVARIANTLAYER VALUES(10,7,0,NULL,NULL,0,0),(11,7,1,1,100,0.5,0),(12,7,2,1,NULL,1,0),(20,7,0,2,NULL,2,0),(21,7,1,2,200,2,0);
    INSERT INTO ZVARIANTMETADATA VALUES(100,11,3,2),(200,21,5,1);
'''


def case(adjusted, modified, settings, converged=True):
    columns = {column: [0, 1] for column in settings}
    return dict(expectedAdjusted=adjusted, waits=[dict(converged=converged, settled=converged)], lateChanges={},
                analysis=dict(isModified=modified, defaultVsCombined=dict(Z_PK=[10, 11], ZINDEX=[0, 1], **columns),
                              defaultVsCombinedMetadata={}))


class VariantModifiedProbeTests(unittest.TestCase):
    def test_snapshot_follows_layer_links_and_reads_only_committed_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'fixture.cocatalogdb'
            db = sqlite3.connect(path)
            try:
                db.executescript(SCHEMA)
                entry = probe.snapshot(path, ['tonal.CR3'])['tonal.CR3']
                parts = probe.view(entry)
                self.assertEqual(parts['default']['Z_PK'], 10, 'default layer is linked, not owned by the variant')
                self.assertEqual(parts['combined']['ZEXPOSURE'], .5)
                self.assertIsNone(parts['adjustment'])
                self.assertEqual(parts['combinedMetadata']['ZBASIC_RATING'], 3)
                self.assertIsNone(parts['defaultMetadata'])
                self.assertEqual({row['Z_PK'] for row in entry['layers']}, {10, 11, 12}, 'other variants stay out')
                analysis = probe.analyze(entry, entry)
                self.assertEqual(analysis['isModified'], 0)
                self.assertEqual(analysis['defaultVsCombined']['ZEXPOSURE'], [0, .5])
                self.assertEqual(analysis['changesSinceImport'], {})
                db.execute('UPDATE ZVARIANT SET ZISMODIFIED=1 WHERE Z_PK=1')
                db.execute('UPDATE ZVARIANTLAYER SET ZROTATION=2 WHERE Z_PK=11')
                db.commit()
                later = probe.snapshot(path, ['tonal.CR3'])['tonal.CR3']
                self.assertEqual(probe.changes(entry, later), dict(variant=dict(ZISMODIFIED=[0, 1]), combined=dict(ZROTATION=[0, 2])))
                db.execute('BEGIN EXCLUSIVE'); db.rollback()
            finally:
                db.close()

    def test_missing_or_duplicate_variant_has_no_layers(self):
        self.assertEqual(probe.view(dict(images=[], variants=[], layers=[], metadata=[])), dict.fromkeys(probe.PARTS))
        self.assertIsNone(probe.view(None)['combined'])
        before = dict(images=[], variants=[dict(Z_PK=1, ZIMAGE=1, ZDEFAULTLAYER=10, ZCOMBINEDSETTINGS=11, ZADJUSTMENTLAYER=None)],
                      layers=[dict(Z_PK=10), dict(Z_PK=11)], metadata=[])
        self.assertEqual(probe.changes(before, None)['combined'], dict(present=[True, False]))

    def test_convergence_requires_the_acknowledged_values(self):
        def entry(exposure, rotation=0):
            return dict(images=[], variants=[dict(Z_PK=1, ZIMAGE=1, ZDEFAULTLAYER=None, ZCOMBINEDSETTINGS=11, ZADJUSTMENTLAYER=None)],
                        layers=[dict(Z_PK=11, ZEXPOSURE=exposure, ZROTATION=rotation)], metadata=[])
        self.assertTrue(probe.converged(entry(.50000001), entry(0), {'combined.ZEXPOSURE': .5}))
        self.assertFalse(probe.converged(entry(0), entry(0), {'combined.ZEXPOSURE': .5}))
        self.assertFalse(probe.converged(entry(None), entry(0), {'combined.ZEXPOSURE': .5}))
        self.assertFalse(probe.converged(entry(0), entry(0), {'combined.ZROTATION': probe.CHANGED}))
        self.assertTrue(probe.converged(entry(0, 2), entry(0), {'combined.ZROTATION': probe.CHANGED}))
        self.assertFalse(probe.converged(None, entry(0), {}))

    def test_settle_waits_for_a_quiet_period_after_convergence(self):
        clock = [0.0]
        reads = iter([0, 1, 1, 2] + [2] * 200)
        result = probe.settle(lambda: next(reads), lambda e: e >= 1, 5, 1,
                              clock=lambda: clock[0], sleep=lambda s: clock.__setitem__(0, clock[0] + s))
        self.assertTrue(result['converged'] and result['settled'])
        self.assertEqual([s['entry'] for s in result['samples']], [0, 1, 2], 'a commit after convergence is kept')
        self.assertGreaterEqual(result['observedForMs'], 1300, 'quiet period restarts after the late commit')

    def test_settle_gives_up_and_records_read_errors(self):
        clock = [0.0]
        def read():
            if clock[0] < .15:
                raise sqlite3.OperationalError('database is locked')
            return 0
        result = probe.settle(read, lambda e: e == 1, 2, 1, clock=lambda: clock[0], sleep=lambda s: clock.__setitem__(0, clock[0] + s))
        self.assertFalse(result['converged'] or result['settled'])
        self.assertIsNone(result['convergedAfterMs'])
        self.assertEqual(result['samples'][0]['error'], 'database is locked')
        self.assertLessEqual(result['observedForMs'], 2100)

    def test_verdicts(self):
        tracked = dict(fresh=case(False, 0, []), tonal=case(True, 1, ['ZEXPOSURE']), rating=case(False, 0, []))
        summary = probe.summarize(tracked)
        self.assertEqual((summary['conclusive'], summary['isModifiedTracksAdjustments'], summary['settingsDiffTracksAdjustments']), (True, True, True))
        self.assertEqual(summary['cases']['tonal']['settingsColumns'], ['ZEXPOSURE'], 'link columns are not settings')
        self.assertEqual(summary['cases']['fresh']['settingsColumns'], [])
        flipped = dict(tracked, rating=case(False, 1, []))
        summary = probe.summarize(flipped)
        self.assertEqual((summary['isModifiedTracksAdjustments'], summary['settingsDiffTracksAdjustments']), (False, True))
        for broken in [case(True, 1, ['ZEXPOSURE'], converged=False), dict(case(True, 1, ['ZEXPOSURE']), skippedSteps=['reset'])]:
            summary = probe.summarize(dict(tracked, tonal=broken))
            self.assertEqual((summary['conclusive'], summary['isModifiedTracksAdjustments'], summary['settingsDiffTracksAdjustments']), (False, None, None))
        missing = case(True, 1, [])
        missing['analysis']['defaultVsCombined'] = None
        self.assertIsNone(probe.summarize(dict(tracked, tonal=missing))['isModifiedTracksAdjustments'])


if __name__ == '__main__': unittest.main()
