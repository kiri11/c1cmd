#!/usr/bin/env python3
"""Edit existing variants through CLI/MCP in disposable Sessions and referenced Catalogs.
Requires C1_TEST_RAW_FIXTURE and zero open documents. Never imports inside a catalog.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from catalog_integration_test import apple, sha, CLI, MCP, ROOT
from contract_test import Client, validate_response


def main():
    raw = Path(os.environ['C1_TEST_RAW_FIXTURE']).resolve()
    assert raw.is_file()
    example = Path(os.environ.get('C1_TEST_CROP_EXAMPLE', ROOT / 'examples/crop-proposals.py'))
    grade = Path(os.environ.get('C1_TEST_GRADE_EXAMPLE', ROOT / 'examples/grade-folder.py'))
    assert example.is_file() and grade.is_file(), 'Both packaged examples must be present before live qualification'
    original_sha = sha(raw)
    assert apple('return count of documents') == '0', 'Close documents before qualification'
    assert json.loads(apple('return version')) == '16.8.5.30'
    evidence = Path(os.environ.get('C1_EXISTING_EVIDENCE', tempfile.mkdtemp(prefix='c1-existing-evidence-', dir='/private/tmp')))
    evidence.mkdir(parents=True, exist_ok=True)
    events = []
    contract = json.loads(subprocess.check_output([str(CLI), 'schema'], text=True))

    def log(event, **data):
        events.append(dict(event=event, **data))
        (evidence / 'results.json').write_text(json.dumps(events, indent=2) + '\n')
        print(event, flush=True)

    log('environment', cliSHA256=sha(CLI), mcpSHA256=sha(MCP), sourceSHA256=original_sha, contract=contract['version'])
    for kind in ['session', 'catalog']:
        base = Path(tempfile.mkdtemp(prefix='c1-existing-live-', dir='/private/tmp'))
        client = None
        succeeded = False
        environment = dict(os.environ)
        environment.pop('C1_MCP_PROFILE', None)
        environment.pop('C1_CATALOG_WRITE_PATH', None)
        package = base / 'existing.cocatalog'
        if kind == 'catalog':
            environment['C1_CATALOG_WRITE_PATH'] = str(package)

        def cli(*args, error=None):
            result = subprocess.run([str(CLI), *map(str, args), '--format', 'json'], env=environment,
                                    capture_output=True, text=True, timeout=150)
            value = json.loads(result.stderr if result.returncode else result.stdout)
            if error:
                assert result.returncode != 0 and value['error']['code'] == error, value
            else:
                assert result.returncode == 0, value
            return value

        def tool(name, args, error=None):
            result = client.tool(name, args)
            value = json.loads(result['content'][0]['text'])
            if error:
                assert result.get('isError') and value['error']['code'] == error, value
            else:
                assert not result.get('isError'), value
                validate_response(value, contract['responses'][name], name)
            return value, result

        try:
            apple(f'make new document with properties {{name:"existing", kind:{kind}, path:"{base}"}}')
            fixture = (base / 'existing/Capture' if kind == 'session' else base) / ('fixture' + raw.suffix)
            fixture.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(raw, fixture)
            if kind == 'session':
                apple('set current collection of current document to collection "Capture" of current document')
            else:
                apple('set destination type of import settings of current document to current location\n'
                      f'import current document source {{"{fixture}"}}')
            for _ in range(40):
                variants = cli('variants', 'list')
                if variants:
                    break
                time.sleep(.5)
            assert len(variants) == 1
            source_id = variants[0]['id']
            apple(f'set rating of variant id "{source_id}" of current document to 5')
            assert [v['id'] for v in cli('variants', 'list', '--rating', '5')] == [source_id]
            source = cli('get', source_id)
            doc = cli('doc', 'info')
            health = cli('doctor')
            assert health['allChecksPassed'] and health['writesEnabled']
            client = Client(MCP, env=environment, timeout=150)
            edit, _ = tool('variant_edit', {'sourceRef': source_id, 'ifState': source['stateHash'],
                                          'ifGeometryState': source['geometryStateHash'], 'ifDocument': doc['openToken']})
            ref = edit['workingRef']
            assert ref.startswith('c1_edit_') and edit['variantId'] == source_id
            assert len(cli('variants', 'list')) == 1
            assert not cli('variants', 'list')[0]['isManagedWorkingClone']
            cli('variant', 'delete', ref, error='unmanaged-variant')
            # Classification writes use a separate token and preserve the image edit.
            baseline_metadata = edit['baselineMetadata']
            assert baseline_metadata == {'rating': 5, 'colorTag': source['metadata']['colorTag']}
            token = source['metadataStateHash']
            dry, _ = tool('metadata_set', {'workingRef': ref, 'ifMetadataState': token, 'rating': 0, 'colorTag': 7, 'dryRun': True})
            assert dry['metadataStateHash'] == token and cli('get', ref)['metadataStateHash'] == token
            cli('metadata', 'set', source_id, '--if-metadata-state', token, '--rating', 1, error='unmanaged-variant')
            metadata_operations = []
            for rating in range(6):
                result = cli('metadata', 'set', ref, '--if-metadata-state', token, '--rating', rating)
                validate_response(result, contract['responses']['metadata_set'])
                assert result['after'] == {'rating': rating, 'colorTag': baseline_metadata['colorTag']}
                token = result['metadataStateHash']
                metadata_operations.append(result['operationId'])
                assert [v['id'] for v in cli('variants', 'list', '--rating', rating)] == [source_id]
            for tag in range(8):
                result, _ = tool('metadata_set', {'workingRef': ref, 'ifMetadataState': token, 'colorTag': tag})
                assert result['after'] == {'rating': 5, 'colorTag': tag}
                token = result['metadataStateHash']
                metadata_operations.append(result['operationId'])
            state = cli('get', ref)
            assert state['stateHash'] == source['stateHash'] and state['geometryStateHash'] == source['geometryStateHash']
            assert state['metadata']['colorTag'] == 7
            # Simulate normal photographer changes between turns, not timeout injection.
            apple(f'set rating of variant id "{source_id}" of current document to 2')
            tool('metadata_set', {'workingRef': ref, 'ifMetadataState': token, 'colorTag': 4}, error='state-changed')
            current = cli('get', ref)
            restored_metadata, _ = tool('metadata_set', {'workingRef': ref, 'ifMetadataState': current['metadataStateHash'], **baseline_metadata})
            assert restored_metadata['after'] == baseline_metadata
            metadata_diff, _ = tool('diff', {'ref1': ref})
            assert not metadata_diff['metadataDiff']
            metadata_entry, _ = tool('operation_status', {'operationId': metadata_operations[-1]})
            assert metadata_entry['status'] == 'succeeded' and metadata_entry['afterMetadata'] == {'rating': 5, 'colorTag': 7}
            assert sha(fixture) == original_sha and sha(raw) == original_sha
            log(kind + '-metadata', operations=metadata_operations, restored=restored_metadata, journal=metadata_entry,
                ratings=list(range(6)), colorTags=list(range(8)), rawSHA256=sha(fixture))
            changed = cli('set', ref, '--if-state', source['stateHash'], 'exposure=0.5', 'contrast=5', 'saturation=8', 'temperature=5100', 'tint=2')
            tool('set', {'workingRef': ref, 'ifState': source['stateHash'], 'exposure': 1}, error='state-changed')
            added, _ = tool('add', {'workingRef': ref, 'ifState': changed['stateHash'], 'exposure': .25})
            reset = cli('reset', ref, '--if-state', added['stateHash'])
            assert reset['after']['exposure'] == 0 and reset['after']['contrast'] == 0
            state = cli('get', ref)
            crop, _ = tool('geometry_set', {'workingRef': ref, 'ifGeometryState': state['geometryStateHash'], 'rotation': 2, 'aspectRatio': .75, 'keystone': {'vertical': 10, 'horizontal': -5}})
            tool('geometry_restore', {'workingRef': ref, 'ifGeometryState': state['geometryStateHash']}, error='state-changed')
            preview, blocks = tool('preview', {'ref': ref})
            assert any(block['type'] == 'image' for block in blocks['content'])
            assert preview['nativeVariantId'] == source_id and preview['workingRef'] == ref
            assert abs(preview['width'] / preview['height'] - .75) < .003
            # Further editing uses exactly the same native variant, with its new crop.
            next_edit, _ = tool('set', {'workingRef': ref, 'ifState': state['stateHash'], 'exposure': .125})
            next_state = cli('get', ref)
            assert next_state['id'] == source_id and next_state['geometry']['crop'] == crop['after']['crop']
            assert next_state['metadata'] == source['metadata']
            restored = cli('geometry', 'restore', ref, '--if-geometry-state', next_state['geometryStateHash'])
            assert restored['after']['crop'] == edit['baselineGeometry']['crop']
            assert restored['after']['rotation'] == edit['baselineGeometry']['rotation']
            assert restored['after']['keystone'] == edit['baselineGeometry']['keystone']
            after_restore = cli('get', ref)
            assert after_restore['stateHash'] == next_edit['stateHash']
            tool('set', {'workingRef': ref, 'ifState': after_restore['stateHash'], 'adjustments': edit['baselineAdjustments']})
            diff, _ = tool('diff', {'ref1': ref})
            assert not diff['geometryDiff']
            assert len(cli('variants', 'list')) == 1
            # The example defaults to editing existing variants, with no --clone flag.
            source_now = cli('get', source_id)
            proposals = base / 'proposals.json'
            proposals.write_text(json.dumps([{'sourceRef': source_id, 'ifGeometryState': source_now['geometryStateHash'],
                'orientation': 'landscape', 'rotation': 0, 'rationale': 'Existing variant integration fixture.'}]))
            process = subprocess.run([sys.executable, '-B', str(example), str(proposals), '--output-dir', str(base / 'reviews'), '--c1-bin', str(CLI)],
                                     env=environment, capture_output=True, text=True, timeout=150)
            assert process.returncode == 0, process.stderr
            example_result = json.loads(process.stdout)
            assert example_result['workingRef'].startswith('c1_edit_') and len(cli('variants', 'list')) == 1
            review = json.loads(Path(example_result['reviewRecord']).read_text())
            assert review['mode'] == 'existing' and review['reviewStatus'] == 'unreviewed' and 'clone' not in review
            example_state = cli('get', example_result['workingRef'])
            tool('geometry_restore', {'workingRef': example_result['workingRef'], 'ifGeometryState': example_state['geometryStateHash']})
            process = subprocess.run([sys.executable, '-B', str(grade), '--c1-bin', str(CLI)],
                                     env=environment, capture_output=True, text=True, timeout=150)
            assert process.returncode == 0, process.stderr
            decisions = list((Path(doc['documentPath']) / '.c1/decisions').glob('*.json'))
            assert len(decisions) == 1
            decision = json.loads(decisions[0].read_text())
            assert decision['mode'] == 'existing' and decision['cloneVariantId'] is None
            assert decision['sourceVariantId'] == source_id and len(cli('variants', 'list')) == 1
            final_state = cli('get', ref)
            tool('set', {'workingRef': ref, 'ifState': final_state['stateHash'], 'adjustments': edit['baselineAdjustments']})
            # A read-only catalog configuration cannot use an existing edit permission.
            if kind == 'catalog':
                client.close()
                denied = dict(environment); denied.pop('C1_CATALOG_WRITE_PATH')
                client = Client(MCP, env=denied, timeout=150)
                tool('set', {'workingRef': ref, 'ifState': next_edit['stateHash'], 'exposure': 1}, error='invalid-request')
                tool('metadata_set', {'workingRef': ref, 'ifMetadataState': source['metadataStateHash'], 'rating': 1}, error='invalid-request')
            journal = Path(doc['documentPath']) / '.c1/journal.jsonl'
            records = [json.loads(line) for line in journal.read_text().splitlines()]
            latest = {r['operationId']: r for r in records}
            assert all(r['status'] == 'succeeded' for r in latest.values())
            assert not any(r['operationType'] in ['clone', 'baseline', 'delete'] for r in records)
            assert all(r['nativeVariantId'] == source_id for r in records)
            assert sha(raw) == original_sha and sha(fixture) == original_sha
            shutil.copy2(journal, evidence / (kind + '-journal.jsonl'))
            shutil.copy2(Path(doc['documentPath']) / '.c1/editing.json', evidence / (kind + '-editing.json'))
            log('passed-' + kind, variantId=source_id, variantCount=1, operations=len(latest), document=doc,
                baseline=edit, final=cli('get', ref), preview=preview, noCloneEvents=True, rawUnchanged=True)
            succeeded = True
        finally:
            if client:
                client.close()
            if succeeded:
                expected = str(package if kind == 'catalog' else base / 'existing')
                apple(f'if (id of current document as text) is not "{expected}" then error "Unexpected document"\nclose current document')
                shutil.rmtree(base)
            else:
                log('failed-retained', kind=kind, base=str(base), rawUnchanged=sha(raw) == original_sha)
    log('passed', storage='session-and-referenced-catalog', noDuplicateVariants=True, rawUnchanged=sha(raw) == original_sha)


if __name__ == '__main__':
    main()
