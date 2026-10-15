#!/usr/bin/env python3
"""Record what stored Catalog data shows for photographer edits on a NEW owned Catalog.

Imports one referenced copy of the RAW per case into an owned Catalog fixture
(Tests/editing_fixture.py), edits each copy only through a c1 editing reference with
a fresh token per write, and after each acknowledged write waits until committed
SQLite data shows it and then stays unchanged for a settle period. Records each
variant's ZVARIANT row (ZISMODIFIED and the layer links), its default, combined and
adjustment ZVARIANTLAYER rows and their metadata rows, and the columns that differ.
Requires zero open documents. Failed or uncertain writes stop at once, without retry,
and leave the fixture open. Never quits Capture One; closes only its own Catalog.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Tests'))
from catalog_integration_test import apple
from editing_fixture import EditingFixture
import stored_read

CHANGED = 'changed'
STRUCTURAL = frozenset({'Z_PK', 'Z_ENT', 'ZINDEX', 'ZVARIANT', 'ZMETADATA', 'ZLAYER'})
LINKS = ('ZDEFAULTLAYER', 'ZCOMBINEDSETTINGS', 'ZADJUSTMENTLAYER')
PARTS = ('variant', 'image', 'default', 'combined', 'adjustment', 'defaultMetadata', 'combinedMetadata')


def tonal(ref, current):
    return ['set', ref, '--if-state', current['stateHash'], 'exposure=0.5'], {'combined.ZEXPOSURE': .5}


def geometry(ref, current):
    return (['geometry', 'set', ref, '--if-geometry-state', current['geometryStateHash'], '--rotation', 2, '--aspect-ratio', 1.5],
            {'combined.ZROTATION': CHANGED})


def metadata(ref, current):
    return (['metadata', 'set', ref, '--if-metadata-state', current['metadataStateHash'], '--rating', 3, '--color-tag', 2],
            {'combinedMetadata.ZBASIC_RATING': 3, 'combinedMetadata.ZCOLOR_TAG_INDEX': 2})


def reset(ref, current):
    return ['reset', ref, '--if-state', current['stateHash']], {'combined.ZEXPOSURE': CHANGED}


# (case, a photographer adjustment remains afterwards, steps)
CASES = (
    ('fresh-import', False, ()),
    ('tonal', True, (tonal,)),
    ('geometry', True, (geometry,)),
    ('metadata-only', False, (metadata,)),
    ('reset-after-tonal', False, (tonal, reset)),
)


def stored_variant(db, filename):
    def rows(sql, *args):
        return [dict(r) for r in db.execute(sql, args)]
    images = rows('SELECT * FROM ZIMAGE WHERE ZIMAGEFILENAME=? ORDER BY Z_PK', filename)
    variants = rows('SELECT v.* FROM ZVARIANT v JOIN ZIMAGE i ON i.Z_PK=v.ZIMAGE WHERE i.ZIMAGEFILENAME=? ORDER BY v.Z_PK', filename)
    entry = dict(images=images, variants=variants, layers=[], metadata=[])
    if len(variants) == 1:
        v = variants[0]
        owned = 'ZVARIANT=? OR Z_PK IN (?,?,?)'
        keys = (v['Z_PK'], *(v[link] for link in LINKS))
        entry['layers'] = rows(f'SELECT * FROM ZVARIANTLAYER WHERE {owned} ORDER BY Z_PK', *keys)
        entry['metadata'] = rows(f'SELECT * FROM ZVARIANTMETADATA WHERE Z_PK IN (SELECT ZMETADATA FROM ZVARIANTLAYER WHERE {owned}) ORDER BY Z_PK', *keys)
    return entry


def snapshot(database, filenames):
    def query(db):
        db.row_factory = sqlite3.Row
        return {name: stored_variant(db, name) for name in filenames}
    return stored_read.read(database, query)


def view(entry):
    parts = dict.fromkeys(PARTS)
    if not entry or len(entry['variants']) != 1:
        return parts
    v = parts['variant'] = entry['variants'][0]
    parts['image'] = next((i for i in entry['images'] if i['Z_PK'] == v['ZIMAGE']), None)
    layers = {row['Z_PK']: row for row in entry['layers']}
    rows = {row['Z_PK']: row for row in entry['metadata']}
    for part, link in zip(('default', 'combined', 'adjustment'), LINKS):
        parts[part] = layers.get(v[link])
    for part in ('default', 'combined'):
        parts[part + 'Metadata'] = rows.get((parts[part] or {}).get('ZMETADATA'))
    return parts


def converged(entry, before, expected):
    now, then = view(entry), view(before)
    if now['combined'] is None:
        return False
    for key, value in expected.items():
        part, column = key.split('.')
        observed = (now[part] or {}).get(column)
        if value == CHANGED:
            if observed == (then[part] or {}).get(column):
                return False
        elif not isinstance(observed, (int, float)) or abs(observed - value) > 1e-4:
            return False
    return True


def settle(read, done, converge_seconds, settle_seconds, clock=time.monotonic, sleep=time.sleep):
    """Poll until done(entry) holds and then nothing changes for settle_seconds."""
    start = clock()
    samples, reached, changed = [], None, None
    while True:
        at = clock()
        try:
            entry, error = read(), None
        except sqlite3.Error as e:
            entry, error = None, str(e)
        if not samples or (entry, error) != (samples[-1]['entry'], samples[-1]['error']):
            samples.append(dict(afterMs=round((at - start) * 1000), entry=entry, error=error))
            changed = at
        if reached is None and entry is not None and done(entry):
            reached = at
        quiet = reached is not None and at - max(reached, changed) >= settle_seconds
        if quiet or at - start >= converge_seconds + (settle_seconds if reached is not None else 0):
            break
        sleep(.1)
    return dict(converged=reached is not None, settled=quiet,
                convergedAfterMs=None if reached is None else round((reached - start) * 1000),
                observedForMs=round((at - start) * 1000), samples=samples)


def diff(a, b):
    if a is None or b is None:
        return None
    return {column: [a.get(column), b.get(column)] for column in sorted(set(a) | set(b)) if a.get(column) != b.get(column)}


def changes(before, after):
    then, now = view(before), view(after)
    result = {}
    for part in PARTS:
        if (then[part] is None) != (now[part] is None):
            result[part] = dict(present=[then[part] is not None, now[part] is not None])
        elif d := diff(then[part], now[part]):
            result[part] = d
    return result


def analyze(entry, imported):
    now = view(entry)
    return dict(variantRows=len(entry['variants']) if entry else 0,
                isModified=(now['variant'] or {}).get('ZISMODIFIED'),
                layerLinks={link: (now['variant'] or {}).get(link) for link in LINKS},
                rows={part: now[part] for part in PARTS},
                defaultVsCombined=diff(now['default'], now['combined']),
                defaultVsCombinedMetadata=diff(now['defaultMetadata'], now['combinedMetadata']),
                defaultVsAdjustment=diff(now['default'], now['adjustment']),
                changesSinceImport=changes(imported, entry))


def summarize(cases):
    rows = {}
    for name, case in cases.items():
        a = case['analysis']
        rows[name] = dict(expectedAdjusted=case['expectedAdjusted'], isModified=a['isModified'],
                          settingsColumns=sorted(set(a['defaultVsCombined'] or {}) - STRUCTURAL),
                          metadataColumns=sorted(set(a['defaultVsCombinedMetadata'] or {}) - STRUCTURAL),
                          conclusive=bool(case['waits']) and all(w['converged'] and w['settled'] for w in case['waits'])
                                     and not case.get('skippedSteps') and a['defaultVsCombined'] is not None,
                          lateChanges=sorted(case['lateChanges']))
    conclusive = all(r['conclusive'] for r in rows.values())
    def tracks(signal):
        return all(signal(r) == r['expectedAdjusted'] for r in rows.values()) if conclusive else None
    return dict(cases=rows, conclusive=conclusive,
                isModifiedTracksAdjustments=tracks(lambda r: bool(r['isModified'])),
                settingsDiffTracksAdjustments=tracks(lambda r: bool(r['settingsColumns'])),
                casesWithLateChanges=[name for name, r in rows.items() if r['lateChanges']])


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def now():
    return datetime.now(timezone.utc).isoformat()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--cli', default=str(ROOT / '.build/debug/c1'))
    p.add_argument('--raw', default=os.environ.get('C1_TEST_RAW_FIXTURE'))
    p.add_argument('--evidence', default=os.environ.get('C1_VARIANT_MODIFIED_EVIDENCE'),
                   help='New JSON file; default .build/qualification/variant-modified-<UTC time>.json')
    p.add_argument('--converge-seconds', type=float, default=60)
    p.add_argument('--settle-seconds', type=float, default=10)
    a = p.parse_args()
    if not a.raw:
        p.error('Pass --raw or set C1_TEST_RAW_FIXTURE')
    if not 0 < a.converge_seconds <= 300 or not 0 < a.settle_seconds <= 60:
        p.error('converge-seconds must be >0...300; settle-seconds must be >0...60')
    evidence = Path(a.evidence or ROOT / '.build/qualification' / f'variant-modified-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}.json').resolve()
    require(not evidence.exists(), f'Evidence file already exists: {evidence}')
    evidence.parent.mkdir(parents=True, exist_ok=True)
    cli_path = Path(a.cli).resolve()
    os.environ['C1_TEST_DOCUMENT_KIND'] = 'catalog'
    record = dict(probe='variant-modified', issue=24, startedAt=now(), cli=str(cli_path), cliSHA256=sha(cli_path),
                  convergeSeconds=a.converge_seconds, settleSeconds=a.settle_seconds,
                  layout=os.environ.get('C1_TEST_CATALOG_LAYOUT', 'package'), events=[], cases={})

    def log(kind, **data):
        record['events'].append(dict(event=kind, observedAt=now(), **data))
        evidence.write_text(json.dumps(record, indent=2, default=lambda v: v.hex() if isinstance(v, bytes) else str(v)) + '\n')
        print(kind, flush=True)

    owned = EditingFixture('modified', a.raw, lambda name, value: log(name, value=value))

    def cli(*args):
        args = [str(x) for x in args]
        try:
            r = subprocess.run([str(cli_path), *args, '--format', 'json'], env=owned.environment, capture_output=True, text=True, timeout=180)
        except subprocess.TimeoutExpired as e:
            log('cli-timeout', args=args, stdout=e.stdout, stderr=e.stderr)
            raise RuntimeError('c1 timed out: outcome unknown. Do not retry; use operation_status after restart.')
        if r.returncode:
            log('cli-failure', args=args, returncode=r.returncode, stdout=r.stdout, stderr=r.stderr)
            raise RuntimeError('c1 failed; fixture retained. No retry or automatic restore.')
        return json.loads(r.stdout)

    try:
        owned.open(cli)
        record['fixture'] = owned.details()
        files = {'fresh-import': owned.fixture}
        for name, _, _ in CASES[1:]:
            files[name] = owned.base / (name + owned.raw.suffix)
            shutil.copy2(owned.raw, files[name])
            owned.import_referenced(files[name])
            apple('set current collection of current document to collection "All Images" of current document')
            for _ in range(40):
                variants = cli('variants', 'list')
                if any(Path(v['parentImagePath']).resolve() == files[name] for v in variants):
                    break
                time.sleep(.5)
        by_path = {}
        for v in variants:
            by_path.setdefault(Path(v['parentImagePath']).resolve(), []).append(v['id'])
        require(len(variants) == len(CASES) and all(len(by_path.get(path, ())) == 1 for path in files.values()),
                'Expected exactly one variant per imported copy.')
        ids = {name: by_path[path][0] for name, path in files.items()}
        doc = cli('doc', 'info')
        require(Path(doc['documentPath']).resolve() == owned.document, 'The open document is not the owned fixture.')
        databases = list(owned.document.glob('*.cocatalogdb'))
        require(len(databases) == 1, 'Expected one database in the owned Catalog.')
        database = databases[0]
        filenames = [path.name for path in files.values()]
        log('cases', ids=ids, files={name: str(path) for name, path in files.items()}, database=str(database))

        def read_all():
            return snapshot(database, filenames)
        initial = settle(read_all, lambda s: all(view(e)['combined'] is not None for e in s.values()), a.converge_seconds, a.settle_seconds)
        log('stored-import', **initial)
        require(initial['converged'], 'Imported variants never appeared in stored data; no write was made.')
        imported = next((sample['entry'] for sample in reversed(initial['samples']) if sample['entry'] is not None), None)
        require(imported is not None, 'No readable stored sample after import; no write was made.')
        settled = {}
        for name, adjusted, steps in CASES:
            filename = files[name].name
            case = record['cases'][name] = dict(expectedAdjusted=adjusted, nativeID=ids[name], filename=filename,
                                                steps=[step.__name__ for step in steps], waits=[])
            if not steps:
                case['waits'].append(dict(step='import', **{k: initial[k] for k in ('converged', 'settled', 'convergedAfterMs', 'observedForMs')}))
                case['nativeAfter'] = cli('get', ids[name])
                settled[name] = imported[filename]
                continue

            def read_one():
                return snapshot(database, [filename])[filename]
            source = cli('get', ids[name])
            doc = cli('doc', 'info')
            ref = case['workingRef'] = cli('variant', 'edit', ids[name], '--if-state', source['stateHash'], '--if-document', doc['openToken'])['workingRef']
            for index, step in enumerate(steps):
                before = read_one()
                current = cli('get', ref)
                args, expected = step(ref, current)
                result = cli(*args)
                log('mutation-acknowledged', case=name, step=step.__name__, args=[str(x) for x in args], result=result)
                wait = settle(read_one, lambda e: converged(e, before, expected), a.converge_seconds, a.settle_seconds)
                log('stored-wait', case=name, step=step.__name__, expected=expected, before=before, **wait)
                case['waits'].append(dict(step=step.__name__, expected=expected, **{k: wait[k] for k in ('converged', 'settled', 'convergedAfterMs', 'observedForMs')}))
                case['nativeAfter'] = cli('get', ref)
                settled[name] = wait['samples'][-1]['entry']
                if not wait['converged']:
                    case['skippedSteps'] = [s.__name__ for s in steps[index + 1:]]
                    break
        final = settle(read_all, lambda s: True, a.converge_seconds, a.settle_seconds)
        log('stored-final', **final)
        latest = final['samples'][-1]['entry'] or {}
        for name, case in record['cases'].items():
            entry = latest.get(case['filename'])
            case['analysis'] = analyze(entry, imported[case['filename']])
            case['lateChanges'] = changes(settled[name], entry)
        record['summary'] = summarize(record['cases'])
        log('summary', **record['summary'])
        preview = cli('preview', record['cases']['tonal']['workingRef'])
        require(all(sha(path) == owned.original for path in files.values()), 'A referenced original changed.')
        owned.verify([preview], provenance_files=('editing.json',))
        owned.close()
        log('passed', closedOwnedDocument=True, fixture=str(owned.base))
        print(json.dumps(record['summary'], indent=2))
    except BaseException as e:
        log('failed-retained', error=repr(e), fixture=str(owned.base))
        raise


if __name__ == '__main__':
    main()
