#!/usr/bin/env python3
"""Opt-in Catalog CLI/MCP qualification, using copied RAWs and zero open documents.

C1_TEST_RAW_FIXTURE is required. C1_CATALOG_EVIDENCE retains JSON evidence;
failed runs retain their disposable catalog for recovery, with no automatic retry.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

from contract_test import Client, validate_response, complete, complete_args

ROOT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get('C1_TEST_BIN', ROOT / '.build/debug/c1'))
MCP = Path(os.environ.get('C1_TEST_MCP_BIN', ROOT / '.build/debug/c1-mcp'))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def apple(body):
    result = subprocess.run(['osascript', '-s', 's', '-e',
        'tell application "/Applications/Capture One.app"\n' + body + '\nend tell'],
        capture_output=True, text=True, timeout=150)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def close_retained(document):
    """Close a failed run's owned document, whose files stay on disk, so the next suite can start.

    Any other open document stays open. Returns what happened, for the failure evidence."""
    try:
        count = apple('return count of documents')
        if count == '0':
            return 'already closed'
        if count != '1':
            return 'left open: not the only open document'
        current = json.loads(apple('return id of current document as text'))
        if Path(current).resolve() != Path(document).resolve():
            return f'left open: current document is {current}'
        apple(f'if (id of current document as text) is not {json.dumps(current)} then error "Document changed"\nclose current document')
        return 'closed'
    except Exception as error:
        return f'left open: {error}'


def snapshot_database(database, destination):
    """Copy the stored state before a close lets Capture One write again."""
    result = subprocess.run([str(CLI), 'catalog', 'snapshot', '--database', str(database), '--destination', str(destination),
                             '--format', 'json'], capture_output=True, text=True, timeout=150)
    return str(destination) if result.returncode == 0 else f'not copied: {result.stderr.strip()}'


def main():
    raw = Path(os.environ['C1_TEST_RAW_FIXTURE']).resolve()
    assert raw.is_file()
    assert apple('return count of documents') == '0', 'Close documents before catalog qualification'
    assert json.loads(apple('return version')) == '16.8.5.30'
    base = Path(tempfile.mkdtemp(prefix='c1-catalog-live-', dir='/private/tmp'))
    layout = os.environ.get('C1_TEST_CATALOG_LAYOUT', 'package')
    assert layout in ['package', 'unpackaged']
    catalog = base / ('qualification.cocatalog' if layout == 'package' else 'qualification')
    evidence = Path(os.environ.get('C1_CATALOG_EVIDENCE', str(base / 'evidence')))
    evidence.mkdir(parents=True, exist_ok=True)
    events = []
    source_sha = sha(raw)
    environment = dict(os.environ, C1_CATALOG_WRITE_PATH=str(catalog))
    contract = json.loads(subprocess.check_output([str(CLI), 'schema'], text=True))
    client = None
    succeeded = False

    def log(event, **data):
        events.append(dict(event=event, **data))
        (evidence / 'results.json').write_text(json.dumps(events, indent=2) + '\n')
        print(event, flush=True)

    def cli(*args, error=None, env=None):
        result = subprocess.run([str(CLI), *complete(args), '--format', 'json'],
                                env=environment if env is None else env,
                                capture_output=True, text=True, timeout=150)
        data = json.loads(result.stderr if result.returncode else result.stdout)
        if error:
            assert result.returncode != 0 and data['error']['code'] == error, data
            validate_response(data, contract['definitions']['Error'])
        else:
            assert result.returncode == 0, data
        return data

    def tool(name, args, error=None):
        result = client.tool(name, complete_args(name, args))
        data = json.loads(result['content'][0]['text'])
        if error:
            assert result.get('isError') and data['error']['code'] == error, data
        else:
            assert not result.get('isError'), data
            validate_response(data, contract['responses'][name], name)
        return data, result

    try:
        apple(f'make new document with properties {{name:"qualification", kind:catalog, path:"{base}"}}')
        if layout == 'unpackaged':
            # Change only our newly created, empty fixture before acquiring any c1 references.
            packaged = base / 'qualification.cocatalog'
            apple(f'if (id of current document as text) is not "{packaged}" then error "Unexpected document"\nclose current document')
            packaged.rename(catalog)
            databases = list(catalog.glob('*.cocatalogdb'))
            assert len(databases) == 1
            environment['C1_CATALOG_WRITE_PATH'] = str(databases[0])
            apple(f'open POSIX file "{databases[0]}"')
        fixture_paths = []
        # Both catalog storage modes: external reference and managed original inside package.
        storage = os.environ.get('C1_TEST_CATALOG_STORAGE', 'referenced')
        assert storage in ['referenced', 'managed']
        for label, destination in [(storage, 'inside catalog' if storage == 'managed' else 'current location')]:
            fixture = base / (label + raw.suffix)
            shutil.copy2(raw, fixture)
            fixture_paths.append(fixture)
            apple(f'set destination type of import settings of current document to {destination}\n'
                  'set import naming format of import settings of current document to "[Image Name]"\n'
                  'set exclude duplicates of import settings of current document to false\n'
                  'set backup of import settings of current document to false\n'
                  'set auto adjust of import settings of current document to false\n'
                  f'import current document source {{"{fixture}"}}')
            for _ in range(40):
                variants = cli('variants', 'list')
                if len(variants) == len(fixture_paths):
                    break
                time.sleep(.5)
            assert len(variants) == len(fixture_paths), variants
            time.sleep(2)
        originals = {item['id']: cli('get', item['id']) for item in variants}
        original_files = {item['parentImagePath']: sha(Path(item['parentImagePath'])) for item in variants}
        assert all((str(catalog) in path) == (storage == 'managed') for path in original_files), original_files
        health = cli('doctor')
        assert health['allChecksPassed'] and health['writesEnabled'] and not health['isSession'], health
        doc = cli('doc', 'info')
        assert Path(doc['documentPath']).resolve() == catalog.resolve() and '.cocatalogdb|' in doc['openToken'], doc
        log('environment', document=doc, sourceSHA256=source_sha, cliSHA256=sha(CLI), mcpSHA256=sha(MCP))
        # Exercise the application's native backup before editing this disposable catalog.
        backup = base / 'backup'
        backup.mkdir()
        apple(f'backup now current document location "{backup}" test integrity true optimize false')
        assert list(backup.rglob('*.cocatalogdb')), 'Native catalog backup missing'
        log('native-backup-created')
        if storage == 'managed':
            cli('variant', 'clone', variants[0]['id'], error='invalid-request')
            cli('preview', variants[0]['id'], error='invalid-request')
            assert sha(raw) == source_sha
            assert all(sha(Path(path)) == checksum for path, checksum in original_files.items())
            log('passed-storage-guard', editingSupported=False, originalsUnchanged=True)
            succeeded = True
            return
        denied_env = dict(environment)
        denied_env.pop('C1_CATALOG_WRITE_PATH')
        wrong_env = dict(environment, C1_CATALOG_WRITE_PATH=str(base / 'wrong.cocatalog'))
        for env, reason in [(denied_env, 'unset'), (wrong_env, 'different-catalog')]:
            info = cli('doc', 'info', env=env)
            assert not info['writesEnabled'] and info['writesDisabledReason'] == reason, info
            assert cli('doctor', env=env)['writesDisabledReason'] == reason
            cli('variant', 'clone', variants[0]['id'], error='invalid-request', env=env)
            cli('preview', variants[0]['id'], error='invalid-request', env=env)
        if layout == 'unpackaged':
            directory_env = dict(environment, C1_CATALOG_WRITE_PATH=str(catalog))
            info = cli('doc', 'info', env=directory_env)
            assert not info['writesEnabled'] and info['writesDisabledReason'] == 'database-path-required', info
            cli('variant', 'clone', variants[0]['id'], error='invalid-request', env=directory_env)
        log('default-and-wrong-path-denied', layout=layout)
        database = next(catalog.glob('*.cocatalogdb'))

        def stored(command, *args):
            return cli('catalog', command, '--database', database, *args)

        def pages(command, key, cursor, whole, *args):
            records, after = [], None
            while True:
                page = stored(command, *args, '--limit', 1, *([cursor, after] if after is not None else []))
                assert all(page[k] == whole[k] for k in ('databaseDocumentUUID', 'schemaFingerprint', 'databaseFileIdentity')), (page, whole)
                assert records or 'next' in page, page
                records += page[key]
                after = page.get('next')
                if isinstance(after, dict):
                    after = after.get(key)
                if after is None:
                    return records

        for _ in range(180):
            if len(stored('variants')['variants']) == len(variants):
                break
            time.sleep(.5)
        whole = stored('variants')
        assert len(whole['variants']) == len(variants), whole
        inspected = stored('inspect', '--tables', 'storedSettings')
        settings = inspected['storedSettings']
        assert len(settings) > 1 and pages('inspect', 'storedSettings', '--after-pk', inspected, '--tables', 'storedSettings') == settings
        log('stored-pages', variants=len(whole['variants']), storedSettings=len(settings))
        # Owned collections: a nested album and a top-level album share one name.
        apple('tell current document\n'
              'set g to make new collection with properties {kind:group, name:"c1 group"}\n'
              'tell g to set a to make new collection with properties {kind:album, name:"c1 album"}\n'
              'make new collection with properties {kind:album, name:"c1 album"}\n'
              f'add inside a variants {{variant id {json.dumps(variants[0]["id"])}}}\n'
              'end tell')
        for _ in range(180):
            listed = stored('collections')['collections']
            nested = [c for c in listed if c['namePath'] == ['c1 group', 'c1 album']]
            if nested and len(stored('variants', '--collection-id', nested[0]['collectionID'])['variants']) == 1:
                break
            time.sleep(.5)
        assert nested, ('Capture One lists collections that SQLite lacks', listed,
                        apple('get name of every collection of current document'))
        validate_response(stored('collections'), contract['responses']['catalog_collections'])
        assert sorted(c['namePath'] for c in listed if c['name'] == 'c1 album') == [['c1 album'], ['c1 group', 'c1 album']], listed
        group = next(c for c in listed if c['namePath'] == ['c1 group'])
        assert nested[0]['parentID'] == group['collectionID'], listed
        assert stored('variants', '--collection', 'c1 group')['collectionID'] == group['collectionID']
        duplicate = cli('catalog', 'variants', '--database', database, '--collection', 'c1 album', error='invalid-request')
        assert f"{nested[0]['collectionID']} (c1 group / c1 album)" in duplicate['error']['message'], duplicate
        cli('catalog', 'variants', '--database', database, '--collection', 'c1 missing', error='invalid-request')
        log('stored-collections', collections=listed)
        # Several variants of one image: each stored variantDatabaseID is its live native ID.
        clone = cli('variant', 'clone', variants[0]['id'])
        for _ in range(180):
            if len(stored('variants')['variants']) == len(variants) + 1:
                break
            time.sleep(.5)
        whole = stored('variants')
        records = whole['variants']
        assert len(records) == len(variants) + 1, ('Capture One lists a clone that SQLite lacks', records,
            apple('get id of every variant of collection "All Images" of current document'))
        assert len({r['imageDatabaseID'] for r in records}) == len(variants), records
        assert pages('variants', 'variants', '--after-variant-id', whole) == records
        log('stored-variant-pages', variants=len(records))
        mapping = []
        for record in records:
            live = cli('variants', 'list', '--ids', record['variantDatabaseID'], '--fields', 'summary')
            assert [(v['id'], v['name'], Path(v['parentImagePath']).resolve()) for v in live] == [
                (str(record['variantDatabaseID']), record['name'], Path(record['originalPath']).resolve())], (record, live)
            cli('get', record['variantUUID'], '--live', error='invalid-request')
            mapping.append(dict(stored=record, live=live[0]))
        assert str(clone['cloneVariantId']) in {m['live']['id'] for m in mapping}, (clone, mapping)
        cli('variant', 'delete', clone['workingRef'])
        log('stored-to-live-ids', layout=layout, mapping=mapping)
        client = Client(MCP, env=environment, timeout=150)
        for source in originals.values():
            clone, _ = tool('variant_clone', {'sourceRef': source['id']})
            ref = clone['workingRef']
            current = cli('get', ref)
            cli('set', source['id'], '--if-state', source['stateHash'], 'exposure=0.5', error='unmanaged-variant')
            cli('variant', 'delete', source['id'], error='unmanaged-variant')
            edited = cli('set', ref, '--if-state', current['stateHash'], 'exposure=0.5')
            cli('set', ref, '--if-state', current['stateHash'], 'exposure=1', error='state-changed')
            added, _ = tool('add', {'workingRef': ref, 'ifState': edited['stateHash'], 'exposure': .25})
            reset, _ = tool('reset', {'workingRef': ref, 'ifState': added['stateHash']})
            assert reset['after']['exposure'] == 0
            state = cli('get', ref)
            crop = cli('geometry', 'set', ref, '--if-geometry-state', state['geometryStateHash'], '--rotation', 2, '--aspect-ratio', 1.5)
            tool('geometry_set', {'workingRef': ref, 'ifGeometryState': state['geometryStateHash'], 'rotation': 1}, error='state-changed')
            preview, image = tool('preview', {'ref': ref})
            assert any(block['type'] == 'image' for block in image['content'])
            assert Path(preview['previewPath']).resolve().is_relative_to(base / (catalog.name + '.c1-output/c1-previews'))
            assert abs(preview['width'] / preview['height'] - 1.5) < .003
            initialized_output = json.loads(apple('return POSIX path of (output of current document as alias)'))
            assert Path(initialized_output).resolve() == (base / (catalog.name + '.c1-output')).resolve()
            existing_output = base / 'existing-output'
            existing_output.mkdir(exist_ok=True)
            log('default-output-fixture', path=str(existing_output))
            apple(f'set output of current document to POSIX file "{existing_output}"')
            count = len(cli('variants', 'list'))
            context, _ = tool('preview', {'ref': ref, 'fullFrame': True})
            assert context['contextSourceRef'] == ref and len(cli('variants', 'list')) == count
            preserved_output = json.loads(apple('return POSIX path of (output of current document as alias)'))
            assert Path(preserved_output).resolve() == existing_output.resolve()
            assert cli('get', ref)['geometryStateHash'] == crop['geometryStateHash']
            assert any(item.get('workingRef') == ref for item in cli('variants', 'list'))
            diff, _ = tool('diff', {'ref1': ref})
            assert diff['geometryDiff']['rotation']['after'] == 2
            cli('variant', 'delete', ref)
            baseline = cli('variant', 'baseline', source['id'])
            tool('variant_delete', {'workingRef': baseline['workingRef']})
            after = cli('get', source['id'])
            assert after['stateHash'] == source['stateHash'] and after['geometryStateHash'] == source['geometryStateHash']
            retained_preview = evidence / (source['id'] + '-preview.jpg')
            shutil.copy2(preview['previewPath'], retained_preview)
            log('clone-edit-preview-diff-delete', sourceID=source['id'], imagePath=source['parentImagePath'], preview=preview, retainedPreview=str(retained_preview))
        # Existing-variant ratings use fresh metadata tokens and preserve the photo's look.
        source = cli('get', variants[0]['id'])
        edit, _ = tool('variant_edit', {'sourceRef': source['id'], 'ifState': source['stateHash'],
                                       'ifDocument': doc['openToken']})
        current = cli('get', edit['workingRef'])
        _, _ = tool('metadata_set', {'workingRef': edit['workingRef'],
                         'ifMetadataState': current['metadataStateHash'], 'rating': 5})
        observed = cli('get', edit['workingRef'])
        assert observed['metadata']['rating'] == 5
        assert observed['stateHash'] == source['stateHash']
        assert observed['geometryStateHash'] == source['geometryStateHash']
        assert observed['metadata']['colorTag'] == source['metadata']['colorTag']
        assert len(cli('variants', 'list')) == len(originals)
        tool('metadata_set', {'workingRef': edit['workingRef'],
             'ifMetadataState': observed['metadataStateHash'], 'rating': source['metadata']['rating']})
        restored = cli('get', edit['workingRef'])
        assert restored['metadataStateHash'] == source['metadataStateHash']
        log('existing-variant-rating-restored', layout=layout)
        # Orientation on an owned Catalog clone: each step (+90, +180, -90, -180) reads back, turns the
        # off-centre crop with the canvas inside maximumCrop, previews in that shape, and restores.
        keys = ('centerX', 'centerY', 'width', 'height')

        def inside(crop, bounds):
            return all(abs(crop[c] - bounds[c]) + crop[s] / 2 <= bounds[s] / 2 + 2
                       for c, s in (('centerX', 'width'), ('centerY', 'height')))

        clone, _ = tool('variant_clone', {'sourceRef': variants[0]['id']})
        ref = clone['workingRef']
        initial = cli('get', ref)
        assert initial['geometry']['orientation'] == 0, initial['geometry']
        frame = initial['geometry']['maximumCrop']
        offset, _ = tool('geometry_set', {'workingRef': ref, 'ifGeometryState': initial['geometryStateHash'],
                         'crop': dict(centerX=round(frame['width'] * .4), centerY=round(frame['height'] * .4),
                                      width=round(frame['width'] * .5), height=round(frame['height'] * .5))})
        cli('geometry', 'set', ref, '--if-geometry-state', offset['geometryStateHash'], '--orientation', 90, '--dry-run',
            error='invalid-request')
        previous = cli('get', ref)
        steps = []
        for value in (90, 270, 180, 0):
            result, _ = tool('geometry_set', {'workingRef': ref, 'ifGeometryState': previous['geometryStateHash'],
                             'orientation': value})
            readback = cli('get', ref)
            g, p = readback['geometry'], previous['geometry']
            assert g['orientation'] == value == result['after']['orientation'], (value, result, g)
            assert readback['geometryStateHash'] == result['geometryStateHash'], (value, result)
            assert readback['stateHash'] == initial['stateHash'] and g['rotation'] == p['rotation'], (value, g)
            quarter = (value - p['orientation']) % 180 == 90
            pairs = (('width', 'height'), ('height', 'width')) if quarter else (('width', 'width'), ('height', 'height'))
            assert all(abs(g['crop'][a] - p['crop'][b]) <= 2 for a, b in pairs), ('crop turns rigidly', value, g, p)
            assert all(abs(g['maximumCrop'][a] - p['maximumCrop'][b]) <= 2 for a, b in pairs), ('canvas turns', value, g, p)
            assert inside(g['crop'], g['maximumCrop']), ('crop inside the oriented canvas', value, g)
            preview, _ = tool('preview', {'ref': ref})
            assert (preview['height'] > preview['width']) == (value in (90, 270)), (value, preview)
            assert abs(preview['width'] / preview['height'] - g['crop']['width'] / g['crop']['height']) < .01, (value, preview, g)
            operation = cli('operation', 'status', result['operationId'])
            assert operation['status'] == 'succeeded' and operation['requestedGeometry']['orientation'] == value, operation
            assert operation['beforeGeometry']['orientation'] == p['orientation'], operation
            steps.append(dict(orientation=value, result=result, crop=g['crop'], maximumCrop=g['maximumCrop'], preview=preview))
            previous = readback
        assert all(abs(previous['geometry']['crop'][k] - offset['after']['crop'][k]) <= 2 for k in keys), (previous, offset)
        # A ratio in the same request is planned on the oriented canvas, so the dry run predicts it.
        planned = dict(workingRef=ref, ifGeometryState=previous['geometryStateHash'], orientation=90, aspectRatio=.75)
        dry, _ = tool('geometry_set', dict(planned, dryRun=True))
        portrait, _ = tool('geometry_set', planned)
        assert portrait['after']['orientation'] == 90 and all(abs(portrait['after']['crop'][k] - dry['after']['crop'][k]) <= 2 for k in keys), (dry, portrait)
        assert inside(portrait['after']['crop'], cli('get', ref)['geometry']['maximumCrop']), portrait
        preview, _ = tool('preview', {'ref': ref})
        assert abs(preview['width'] / preview['height'] - .75) < .003, preview
        restored, _ = tool('geometry_restore', {'workingRef': ref, 'ifGeometryState': portrait['geometryStateHash']})
        assert restored['after']['orientation'] == 0 and restored['after']['crop'] == initial['geometry']['crop'], restored
        assert cli('get', ref)['geometryStateHash'] == initial['geometryStateHash'], 'restore returns the saved geometry'
        preview_restored, _ = tool('preview', {'ref': ref})
        assert preview_restored['width'] > preview_restored['height'], preview_restored
        tool('variant_delete', {'workingRef': ref})
        assert {item['id'] for item in cli('variants', 'list')} == set(originals)
        log('catalog-orientation', layout=layout, steps=steps, dryRun=dry, portrait=portrait, preview=preview,
            restored=restored, restoredPreview=preview_restored)
        # Composition tool profile also supports the exact-path opt-in.
        client.close()
        client = Client(MCP, env=dict(environment, C1_TOOL_PROFILE='composition'), timeout=150)
        names = [entry['name'] for entry in client.request('tools/list', {})['tools']]
        assert 'geometry_set' in names and 'set' not in names and 'variant_baseline' not in names
        clone, _ = tool('variant_clone', {'sourceRef': variants[0]['id']})
        current, _ = tool('get', {'ref': clone['workingRef']})
        tool('geometry_set', {'workingRef': clone['workingRef'], 'ifGeometryState': current['geometryStateHash'], 'aspectRatio': .75})
        tool('variant_delete', {'workingRef': clone['workingRef']})
        assert {item['id'] for item in cli('variants', 'list')} == set(originals)
        # One imported copy per qualified case keeps the stored settings cases independent.
        def tonal(ref, current):
            cli('set', ref, '--if-state', current['stateHash'], 'exposure=0.5')

        def geometry(ref, current):
            cli('geometry', 'set', ref, '--if-geometry-state', current['geometryStateHash'], '--rotation', 2, '--aspect-ratio', 1.5)

        def metadata(ref, current):
            cli('metadata', 'set', ref, '--if-metadata-state', current['metadataStateHash'], '--rating', 3, '--color-tag', 2)

        def reset(ref, current):
            cli('reset', ref, '--if-state', current['stateHash'])

        signal_cases = {
            'unchanged': [],
            'tonal': [(tonal, dict(changedSettings=['ZEXPOSURE']))],
            'geometry': [(geometry, dict(changedSettings=['ZCROP', 'ZROTATION']))],
            'metadata-only': [(metadata, dict(changedSettings=[], rating=3, colorTag=2))],
            'reset-after-tonal': [(tonal, dict(changedSettings=['ZEXPOSURE'])), (reset, dict(changedSettings=[]))],
        }
        copies = {name: base / (name + raw.suffix) for name in signal_cases}
        for copy in copies.values():
            shutil.copy2(raw, copy)
            fixture_paths.append(copy)
            apple(f'import current document source {{"{copy}"}}')
            apple('set current collection of current document to collection "All Images" of current document')
            for _ in range(40):
                imported = {Path(v['parentImagePath']).resolve(): v['id'] for v in cli('variants', 'list')}
                if copy.resolve() in imported:
                    break
                time.sleep(.5)
            assert copy.resolve() in imported, (copy, imported)
        signal_ids = {name: imported[copy.resolve()] for name, copy in copies.items()}

        def stored_signal(variant_id, expected):
            want = dict(expected, variantDatabaseID=int(variant_id), settingsChanged=bool(expected['changedSettings']))
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline:
                page = stored('variants', '--after-variant-id', int(variant_id) - 1, '--limit', 1)
                record = next(iter(page['variants']), {})
                if all(record.get(key) == value for key, value in want.items()):
                    break
                time.sleep(.5)
            assert all(record.get(key) == value for key, value in want.items()), (want, record)
            validate_response(page, contract['responses']['catalog_variants'])
            return record

        signals = {}
        for name, steps in signal_cases.items():
            variant_id = signal_ids[name]
            signals[name] = [stored_signal(variant_id, dict(changedSettings=[]))]
            if steps:
                source = cli('get', variant_id)
                ref = cli('variant', 'edit', variant_id, '--if-state', source['stateHash'],
                          '--if-document', cli('doc', 'info')['openToken'])['workingRef']
                for step, expected in steps:
                    step(ref, cli('get', ref))
                    signals[name].append(stored_signal(variant_id, expected))
        final = {name: stored_signal(signal_ids[name], steps[-1][1] if steps else dict(changedSettings=[])) for name, steps in signal_cases.items()}
        reset_variant = cli('get', signal_ids['reset-after-tonal'], '--database', database)['variant']
        assert reset_variant['ZISMODIFIED'] == 1, reset_variant
        log('stored-settings-signal', layout=layout, ids=signal_ids, signals=signals, final=final)
        journal = [json.loads(line) for line in (catalog / '.c1/journal.jsonl').read_text().splitlines()]
        latest = {entry['operationId']: entry for entry in journal}
        assert all(entry['status'] == 'succeeded' for entry in latest.values()), latest
        assert all('.cocatalogdb|' in entry['documentIdentity'] for entry in journal)
        assert not (base / '.c1').exists()
        assert sha(raw) == source_sha
        assert all(sha(path) == source_sha for path in fixture_paths)
        assert all(sha(Path(path)) == checksum for path, checksum in original_files.items())
        log('passed', operations=len(latest), storageModes=[storage], originalsUnchanged=True)
        succeeded = True
    finally:
        if client:
            client.close()
        if succeeded:
            apple(f'if (id of current document as text) is not "{catalog}" then error "Unexpected document"\nclose current document')
            # Keep external evidence; retained default evidence is inside the disposable root.
            if not evidence.is_relative_to(base):
                shutil.rmtree(base)
        else:
            database = next(catalog.glob('*.cocatalogdb'), None)
            snapshot = snapshot_database(database, evidence / 'failed-before-close.cocatalogdb') if database else None
            log('failed-retained', catalog=str(catalog), sourceUnchanged=sha(raw) == source_sha,
                storedSnapshot=snapshot, document=close_retained(catalog))


if __name__ == '__main__':
    main()
