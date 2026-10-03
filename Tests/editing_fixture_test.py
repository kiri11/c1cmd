#!/usr/bin/env python3
"""Offline checks for owned Catalog creation, backup gating and evidence isolation."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import editing_fixture as fixture


class EditingFixtureTests(unittest.TestCase):
    def test_mode_selection(self):
        self.assertEqual(fixture.document_mode({}), ('session', 'package'))
        self.assertEqual(fixture.document_mode({'C1_TEST_DOCUMENT_KIND': 'catalog', 'C1_TEST_CATALOG_LAYOUT': 'unpackaged'}), ('catalog', 'unpackaged'))
        for env in [{'C1_TEST_DOCUMENT_KIND': 'main'}, {'C1_TEST_CATALOG_LAYOUT': 'other'}]:
            with self.assertRaises(ValueError):
                fixture.document_mode(env)

    def test_owned_catalog_setup_and_backup_gate(self):
        for layout in ['package', 'unpackaged']:
            for backup_ok in [True, False]:
                with self.subTest(layout=layout, backup_ok=backup_ok), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp).resolve(); (root / '.build').mkdir()
                    raw = root / 'original.CR3'; raw.write_bytes(b'immutable RAW')
                    env = dict(C1_TEST_DOCUMENT_KIND='catalog', C1_TEST_CATALOG_LAYOUT=layout, C1_CATALOG_WRITE_PATH='/real/main.cocatalog')
                    with patch.dict(os.environ, env), patch.object(fixture, 'ROOT', root):
                        owned = fixture.EditingFixture('native', raw, Mock())
                    self.assertNotIn('C1_CATALOG_WRITE_PATH', owned.environment)
                    current = None
                    calls = []
                    def apple(body):
                        nonlocal current
                        calls.append(body)
                        if body == 'return count of documents': return '1' if current else '0'
                        if body == 'return version': return '"16.8.5.30"'
                        if body == 'return id of current document as text': return json.dumps(str(current))
                        if body.startswith('make new document'):
                            current = owned.base / 'native.cocatalog'; current.mkdir()
                            (current / 'native.cocatalogdb').write_bytes(b'database')
                        elif body == 'close current document': current = None
                        elif body.startswith('open POSIX file'): current = owned.document
                        elif body.startswith('backup now') and backup_ok:
                            (owned.backup / 'backup.cocatalogdb').write_bytes(b'native backup')
                        return ''
                    def cli(*args):
                        if args == ('variants', 'list'):
                            return [dict(id='1', parentImagePath=str(owned.fixture))]
                        if args == ('doctor',):
                            return dict(allChecksPassed=True, writesEnabled=True, exactBuildMatched=True, isSession=False)
                        if args == ('doc', 'info'):
                            return dict(documentId=str(owned.document), documentPath=str(owned.document), openToken='pid:launch|catalog.cocatalogdb|instance')
                        self.fail('Setup must not issue editing commands')
                    with patch.object(fixture, 'apple', apple):
                        if backup_ok:
                            self.assertEqual(owned.open(cli)[0]['id'], '1')
                            owned.close()
                        else:
                            with self.assertRaisesRegex(AssertionError, 'backup missing'):
                                owned.open(cli)
                            self.assertEqual(current, owned.document, 'Failed fixture must remain open')
                    self.assertEqual(raw.read_bytes(), b'immutable RAW')
                    self.assertEqual(owned.fixture.read_bytes(), b'immutable RAW')
                    self.assertFalse(owned.fixture.is_relative_to(owned.document))
                    expected = owned.document if layout == 'package' else owned.document / 'native.cocatalogdb'
                    self.assertEqual(owned.environment['C1_CATALOG_WRITE_PATH'], str(expected))
                    self.assertIn('destination type of import settings of current document to current location', '\n'.join(calls))
                    self.assertEqual(owned.log.call_count, int(backup_ok))

    def test_close_uses_observed_session_id_and_rejects_document_switch(self):
        owned = fixture.EditingFixture.__new__(fixture.EditingFixture)
        owned.document = Path('/owned/session')
        for native_id in ['/owned/session', '/owned/session/session.cosessiondb']:
            owned.native_id = native_id
            with patch.object(fixture, 'apple', side_effect=['1', json.dumps(native_id), '']) as apple:
                owned.close()
                self.assertEqual(apple.call_args.args, ('close current document',))
            with patch.object(fixture, 'apple', side_effect=['1', '"/real/main.cocatalog"']) as apple:
                with self.assertRaises(AssertionError): owned.close()
                self.assertEqual(apple.call_count, 2)

    def test_evidence_rejects_wrong_location_raw_change_and_pending_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); (root / '.build').mkdir()
            raw = root / 'raw.CR3'; raw.write_bytes(b'RAW')
            with patch.dict(os.environ, C1_TEST_DOCUMENT_KIND='catalog', C1_TEST_CATALOG_LAYOUT='package'), patch.object(fixture, 'ROOT', root):
                owned = fixture.EditingFixture('recipes', raw, Mock())
            owned.fixture = owned.base / 'referenced.CR3'; owned.fixture.write_bytes(b'RAW')
            owned.identity = 'catalog.cocatalogdb|instance'
            c1 = owned.document / '.c1'; c1.mkdir(parents=True)
            (c1 / 'provenance.json').write_text('{}')
            (c1 / 'editing.json').write_text('{}')
            journal = c1 / 'journal.jsonl'
            def entry(status):
                journal.write_text(json.dumps(dict(operationId='1', status=status, documentIdentity=owned.identity))+'\n')
            entry('succeeded')
            owned.backup = owned.base / 'backup'; owned.backup.mkdir()
            (owned.backup / 'backup.cocatalogdb').write_bytes(b'backup')
            preview_dir = owned.base / (owned.document.name + '.c1-output') / 'c1-previews'; preview_dir.mkdir(parents=True)
            preview = preview_dir / 'preview.jpg'; preview.write_bytes(b'preview')
            evidence = c1 / 'result.json'; evidence.write_text('{}')
            owned.verify([dict(outputPath=str(preview))], [str(evidence)])
            (c1 / 'provenance.json').unlink()
            owned.verify([dict(outputPath=str(preview))], provenance_files=('editing.json',))
            with self.assertRaises(AssertionError): owned.verify([dict(outputPath=str(preview))])
            (c1 / 'provenance.json').write_text('{}')
            with self.assertRaises(AssertionError): owned.verify([dict(outputPath=str(evidence))])
            with self.assertRaises(AssertionError): owned.verify([dict(outputPath=str(preview))], [str(preview)])
            entry('pending')
            with self.assertRaises(AssertionError): owned.verify([dict(outputPath=str(preview))])
            entry('succeeded'); owned.fixture.write_bytes(b'changed')
            with self.assertRaises(AssertionError): owned.verify([dict(outputPath=str(preview))])


if __name__ == '__main__': unittest.main()
