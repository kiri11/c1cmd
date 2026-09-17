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

from contract_test import Client, validate_response

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


def main():
    raw = Path(os.environ['C1_TEST_RAW_FIXTURE']).resolve()
    assert raw.is_file()
    assert apple('return count of documents') == '0', 'Close documents before catalog qualification'
    assert json.loads(apple('return version')) == '16.8.5.30'
    base = Path(tempfile.mkdtemp(prefix='c1-catalog-live-', dir='/private/tmp'))
    catalog = base / 'qualification.cocatalog'
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
        result = subprocess.run([str(CLI), *map(str, args), '--format', 'json'],
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
        result = client.tool(name, args)
        data = json.loads(result['content'][0]['text'])
        if error:
            assert result.get('isError') and data['error']['code'] == error, data
        else:
            assert not result.get('isError'), data
            validate_response(data, contract['responses'][name], name)
        return data, result

    try:
        apple(f'make new document with properties {{name:"qualification", kind:catalog, path:"{base}"}}')
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
        assert not cli('doc', 'info', env=denied_env)['writesEnabled']
        for env in [denied_env, dict(environment, C1_CATALOG_WRITE_PATH=str(base / 'wrong.cocatalog'))]:
            cli('variant', 'clone', variants[0]['id'], error='invalid-request', env=env)
            cli('preview', variants[0]['id'], error='invalid-request', env=env)
        log('default-and-wrong-path-denied')
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
            assert Path(preview['outputPath']).resolve().is_relative_to(base / 'qualification.cocatalog.c1-output/c1-previews')
            assert abs(preview['width'] / preview['height'] - 1.5) < .003
            initialized_output = json.loads(apple('return POSIX path of (output of current document as alias)'))
            assert Path(initialized_output).resolve() == (base / 'qualification.cocatalog.c1-output').resolve()
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
            log('clone-edit-preview-diff-delete', sourceID=source['id'], imagePath=source['parentImagePath'], preview=preview)
        # Composition MCP profile also supports the exact-path opt-in.
        client.close()
        client = Client(MCP, env=dict(environment, C1_MCP_PROFILE='composition'), timeout=150)
        names = [entry['name'] for entry in client.request('tools/list', {})['tools']]
        assert 'geometry_set' in names and 'set' not in names and 'variant_baseline' not in names
        clone, _ = tool('variant_clone', {'sourceRef': variants[0]['id']})
        current, _ = tool('get', {'ref': clone['workingRef']})
        tool('geometry_set', {'workingRef': clone['workingRef'], 'ifGeometryState': current['geometryStateHash'], 'aspectRatio': .75})
        tool('variant_delete', {'workingRef': clone['workingRef']})
        assert {item['id'] for item in cli('variants', 'list')} == set(originals)
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
            log('failed-retained', catalog=str(catalog), sourceUnchanged=sha(raw) == source_sha)


if __name__ == '__main__':
    main()
