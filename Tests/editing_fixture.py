"""Owned Session/Catalog fixtures shared by native and recipe live qualification."""
import json
import os
from pathlib import Path
import shutil
import tempfile
import time

from catalog_integration_test import ROOT, apple, sha


def document_mode(environment):
    kind = environment.get('C1_TEST_DOCUMENT_KIND', 'session')
    layout = environment.get('C1_TEST_CATALOG_LAYOUT', 'package')
    if kind not in ('session', 'catalog') or layout not in ('package', 'unpackaged'):
        raise ValueError('Select session/catalog and package/unpackaged')
    return kind, layout


class EditingFixture:
    def __init__(self, name, raw, log):
        self.kind, self.layout = document_mode(os.environ)
        self.raw = Path(raw).resolve()
        assert self.raw.is_file()
        self.original = sha(self.raw)
        self.name, self.log = name, log
        self.base = Path(tempfile.mkdtemp(prefix=f'c1-{name}-', dir=str(ROOT / '.build'))).resolve()
        self.document = self.base / (name if self.kind == 'session' or self.layout == 'unpackaged' else name + '.cocatalog')
        self.environment = dict(os.environ)
        self.environment.pop('C1_CATALOG_WRITE_PATH', None)
        self.backup = None

    def assert_current(self):
        assert apple('return count of documents') == '1'
        current = json.loads(apple('return id of current document as text'))
        expected = Path(getattr(self, 'native_id', self.document)).resolve()
        assert Path(current).resolve() == expected, (current, expected)

    def open(self, cli):
        assert apple('return count of documents') == '0', 'Close documents before qualification'
        assert json.loads(apple('return version')) == '16.8.5.30'
        apple(f'make new document with properties {{name:{json.dumps(self.name)}, kind:{self.kind}, path:{json.dumps(str(self.base))}}}')
        if self.kind == 'catalog':
            packaged = self.base / (self.name + '.cocatalog')
            self.environment['C1_CATALOG_WRITE_PATH'] = str(packaged)
            if self.layout == 'unpackaged':
                # Only move the newly created empty Catalog, before acquiring references.
                assert json.loads(apple('return id of current document as text')) == str(packaged)
                apple('close current document')
                packaged.rename(self.document)
                databases = list(self.document.glob('*.cocatalogdb'))
                assert len(databases) == 1
                self.environment['C1_CATALOG_WRITE_PATH'] = str(databases[0])
                apple(f'open POSIX file {json.dumps(str(databases[0]))}')
            self.fixture = self.base / ('referenced' + self.raw.suffix)
            shutil.copy2(self.raw, self.fixture)
            self.assert_current()
            apple('set destination type of import settings of current document to current location\n'
                  'set import naming format of import settings of current document to "[Image Name]"\n'
                  'set exclude duplicates of import settings of current document to false\n'
                  'set backup of import settings of current document to false\n'
                  'set auto adjust of import settings of current document to false\n'
                  f'import current document source {{{json.dumps(str(self.fixture))}}}')
        else:
            self.fixture = self.document / 'Capture' / self.raw.name
            shutil.copy2(self.raw, self.fixture)
            apple('set current collection of current document to collection "Capture" of current document')
        for _ in range(40):
            variants = cli('variants', 'list')
            if variants:
                break
            time.sleep(.5)
        assert len(variants) == 1, variants
        assert Path(variants[0]['parentImagePath']).resolve() == self.fixture
        if self.kind == 'catalog':
            assert not self.fixture.is_relative_to(self.document)
        doctor = cli('doctor')
        assert doctor['allChecksPassed'] and doctor['writesEnabled'] and doctor['exactBuildMatched'], doctor
        assert doctor['isSession'] == (self.kind == 'session'), doctor
        doc = cli('doc', 'info')
        assert Path(doc['documentPath']).resolve() == self.document, doc
        self.native_id = doc['documentId']
        self.identity = doc['openToken'].split('|', 1)[1]
        if self.kind == 'catalog':
            self.backup = self.base / 'backup'
            self.backup.mkdir()
            self.assert_current()
            apple(f'backup now current document location {json.dumps(str(self.backup))} test integrity true optimize false')
            assert list(self.backup.rglob('*.cocatalogdb')), 'Native Catalog backup missing'
        self.log('fixture', self.details())
        return variants

    def details(self):
        return dict(documentKind=self.kind, layout=self.layout if self.kind == 'catalog' else None,
                    document=str(self.document), referencedOriginal=str(self.fixture), rawSHA256=self.original,
                    catalogWritePath=self.environment.get('C1_CATALOG_WRITE_PATH'),
                    backup=str(self.backup) if self.backup else None,
                    c1Directory=str(self.document / '.c1'),
                    previewDirectory=str(self.base / (self.document.name + '.c1-output') / 'c1-previews') if self.kind == 'catalog' else None)

    def verify(self, previews=(), evidence_paths=(), provenance_files=('editing.json', 'provenance.json')):
        assert sha(self.raw) == sha(self.fixture) == self.original
        c1 = self.document / '.c1'
        for name in provenance_files:
            assert (c1 / name).is_file(), name
        entries = [json.loads(line) for line in (c1 / 'journal.jsonl').read_text().splitlines()]
        latest = {row['operationId']: row for row in entries}
        assert latest and all(row['status'] in ('succeeded', 'failed') for row in latest.values()), latest
        assert all(row['documentIdentity'] == self.identity for row in entries)
        assert not (self.base / '.c1').exists()
        for path in evidence_paths:
            assert Path(path).resolve().is_relative_to(c1) and Path(path).is_file(), path
        if self.kind == 'catalog':
            preview_dir = self.base / (self.document.name + '.c1-output') / 'c1-previews'
            assert previews, 'Catalog qualification must retain a preview'
            for preview in previews:
                path = Path(preview['outputPath']).resolve()
                assert path.is_relative_to(preview_dir) and path.is_file(), path
            assert list(self.backup.rglob('*.cocatalogdb'))
        self.log('fixture-verified', dict(self.details(), operations=len(latest), originalsUnchanged=True,
                                         previews=list(previews), evidencePaths=list(evidence_paths),
                                         provenancePaths=[str(c1 / name) for name in provenance_files]))

    def close(self):
        self.assert_current()
        apple('close current document')
