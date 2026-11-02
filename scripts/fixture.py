"""An owned disposable Session or Catalog for live checks, holding a copy of one RAW.

kind, or else C1_TEST_DOCUMENT_KIND, picks session (default) or catalog. The document and its evidence live in a new folder
under .build; environment points C1_HOME and C1_CACHES there, so a check never touches ~/.c1.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BUILD = '16.8.5.30'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def apple(body):
    r = subprocess.run(['osascript', '-s', 's', '-e', 'tell application "/Applications/Capture One.app"\n' + body + '\nend tell'],
                       capture_output=True, text=True, timeout=150)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


class EditingFixture:
    def __init__(self, name, raw, c1, log, kind=None):
        self.kind = kind or os.environ.get('C1_TEST_DOCUMENT_KIND', 'session')
        if self.kind not in ('session', 'catalog'):
            raise ValueError('C1_TEST_DOCUMENT_KIND is session or catalog')
        self.raw = Path(raw).resolve()
        assert self.raw.is_file(), self.raw
        self.original = sha(self.raw)
        self.name, self.c1, self.log = name, str(c1), log
        (ROOT / '.build').mkdir(exist_ok=True)
        self.base = Path(tempfile.mkdtemp(prefix=f'c1-{name}-', dir=str(ROOT / '.build'))).resolve()
        self.document = self.base / (name + '.cocatalog' if self.kind == 'catalog' else name)
        self.environment = dict(os.environ, C1_HOME=str(self.base / 'c1-home'), C1_CACHES=str(self.base / 'caches'))
        self.native_id = None

    def cli(self, command, arguments=None):
        r = subprocess.run([self.c1, command, json.dumps(arguments or {})], env=self.environment,
                           capture_output=True, text=True, timeout=300)
        assert r.returncode == 0, (command, r.stdout, r.stderr)
        return json.loads(r.stdout)

    def assert_current(self):
        assert apple('return count of documents') == '1'
        assert json.loads(apple('return id of current document as text')) == self.native_id

    def open(self):
        """Creates the document, adds the RAW copy, takes a Catalog's first backup; returns list's variants."""
        assert apple('return count of documents') == '0', 'Close every document before a live check'
        assert json.loads(apple('return version')) == BUILD
        apple(f'make new document with properties {{name:{json.dumps(self.name)}, kind:{self.kind}, path:{json.dumps(str(self.base))}}}')
        self.native_id = json.loads(apple('return id of current document as text'))
        if self.kind == 'catalog':
            self.fixture = self.base / ('referenced' + self.raw.suffix)
            shutil.copy2(self.raw, self.fixture)
            self.import_referenced(self.fixture)
        else:
            self.fixture = self.document / 'Capture' / self.raw.name
            shutil.copy2(self.raw, self.fixture)
            apple('set current collection of current document to collection "Capture" of current document')
        # A new document's database can lag Capture One by up to a minute.
        for _ in range(40):
            variants = self.cli('list')['variants']
            if variants:
                break
            time.sleep(3)
        assert len(variants) == 1, variants
        # list gives a path only for a referenced original outside the document.
        assert variants[0]['name'] == self.fixture.stem, variants
        assert self.kind == 'session' or Path(variants[0]['path']).resolve() == self.fixture, variants
        if self.kind == 'catalog':
            self.backup = self.base / 'backup'
            self.backup.mkdir()
            self.assert_current()
            apple(f'backup now current document location {json.dumps(str(self.backup))} test integrity true optimize false')
            assert list(self.backup.rglob('*.cocatalogdb')), 'Native Catalog backup missing'
        doctor = self.cli('doctor')
        assert doctor['captureOne'] == {'version': BUILD, 'tested': True}, doctor
        assert doctor['document']['kind'] == self.kind and Path(doctor['document']['path']).resolve() == self.document, doctor
        self.log('fixture', self.details())
        return variants

    def import_referenced(self, path):
        self.assert_current()
        apple('set destination type of import settings of current document to current location\n'
              'set import naming format of import settings of current document to "[Image Name]"\n'
              'set exclude duplicates of import settings of current document to false\n'
              'set backup of import settings of current document to false\n'
              'set auto adjust of import settings of current document to false\n'
              f'import current document source {{{json.dumps(str(path))}}}')

    def details(self):
        return dict(documentKind=self.kind, document=str(self.document), referencedOriginal=str(getattr(self, 'fixture', None)),
                    rawSHA256=self.original, c1Home=self.environment['C1_HOME'])

    def originals_unchanged(self):
        return sha(self.raw) == sha(self.fixture) == self.original

    def close(self):
        self.assert_current()
        apple('close current document')

    def retain_and_close(self):
        """After a failure: keep the files, and close the owned document only if it is the one open."""
        try:
            count = apple('return count of documents')
            if count == '0':
                outcome = 'already closed'
            elif count != '1' or json.loads(apple('return id of current document as text')) != self.native_id:
                outcome = 'left open: another document is open'
            else:
                apple(f'if (id of current document as text) is not {json.dumps(self.native_id)} then error "Document changed"\nclose current document')
                outcome = 'closed'
        except Exception as error:
            outcome = f'left open: {error}'
        self.log('failed-retained', dict(base=str(self.base), document=outcome))
