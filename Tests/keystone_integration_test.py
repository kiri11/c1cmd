#!/usr/bin/env python3
"""Keystone CLI/MCP qualification in an owned Session; never retry uncertain writes.
Requires C1_TEST_RAW_FIXTURE and zero open documents. Retains evidence and failures.
"""
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import time

from catalog_integration_test import apple, sha, CLI, MCP, ROOT
from contract_test import Client, validate_response


def preview_pixels(path):
    # Use macOS ImageIO through sips; avoid optional Python image dependencies.
    with tempfile.TemporaryDirectory(prefix='c1-keystone-pixels-') as directory:
        output = Path(directory) / 'preview.bmp'
        subprocess.run(['sips', '-s', 'format', 'bmp', str(path), '--out', str(output)], check=True, capture_output=True)
        data = output.read_bytes()
    offset = struct.unpack_from('<I', data, 10)[0]
    width, height = struct.unpack_from('<ii', data, 18)
    bits = struct.unpack_from('<H', data, 28)[0]
    assert bits == 24 and struct.unpack_from('<I', data, 30)[0] == 0
    stride = ((width * bits + 31) // 32) * 4
    rows = [data[offset + y*stride:offset + y*stride + width*3] for y in range(abs(height))]
    if height > 0: rows.reverse()
    return (width, abs(height)), b''.join(rows)


def restored_preview_error(before, restored):
    size, a = preview_pixels(before['outputPath'])
    restored_size, b = preview_pixels(restored['outputPath'])
    assert size == restored_size
    differences = [abs(x-y) for x, y in zip(a, b)]
    metrics = {'meanAbsoluteChannelError':sum(differences)/len(differences),
               'maxChannelError':max(differences), 'meanThreshold':.1}
    # Repeated exports with no intervening edits vary by about .01/255 in
    # this native renderer. Exact geometry/tonal restoration is checked separately.
    assert metrics['meanAbsoluteChannelError'] < metrics['meanThreshold'], metrics
    return metrics


def main():
    raw = Path(os.environ['C1_TEST_RAW_FIXTURE']).resolve()
    source_sha = sha(raw)
    assert apple('return count of documents') == '0'
    assert json.loads(apple('return version')) == '16.8.5.30'
    parent = ROOT / '.build/keystone-qualification'
    parent.mkdir(parents=True, exist_ok=True)
    base = Path(tempfile.mkdtemp(prefix='live-', dir=parent))
    evidence = Path(os.environ.get('C1_KEYSTONE_EVIDENCE', str(base / 'evidence')))
    evidence.mkdir(parents=True, exist_ok=True)
    events = []
    client = None
    success = False

    def log(event, **data):
        events.append(dict(event=event, **data))
        (evidence / 'results.json').write_text(json.dumps(events, indent=2) + '\n')
        print(event, data.get('case', ''), flush=True)

    def cli(*args, error=None):
        result = subprocess.run([str(CLI), *map(str, args), '--format', 'json'], capture_output=True, text=True, timeout=150)
        data = json.loads(result.stderr if result.returncode else result.stdout)
        if error:
            assert result.returncode and data['error']['code'] == error, data
        else:
            assert result.returncode == 0, data
        return data

    contract = cli('schema')

    def tool(name, args, error=None):
        result = client.tool(name, args)
        data = json.loads(result['content'][0]['text'])
        if error:
            assert result.get('isError') and data['error']['code'] == error, data
        else:
            assert not result.get('isError'), data
            validate_response(data, contract['responses'][name], name)
        return data

    try:
        apple(f'make new document with properties {{name:"keystone", kind:session, path:"{base}"}}')
        fixture = base / 'keystone/Capture' / raw.name
        shutil.copy2(raw, fixture)
        apple('set current collection of current document to collection "Capture" of current document')
        for _ in range(40):
            variants = cli('variants', 'list')
            if variants:
                break
            time.sleep(.5)
        assert len(variants) == 1
        health, doc = cli('doctor'), cli('doc', 'info')
        assert health['allChecksPassed'] and health['writesEnabled'] and health['exactBuildMatched']
        source = cli('get', variants[0]['id'])
        baseline = source['geometry']
        edit = cli('variant', 'edit', source['id'], '--if-state', source['stateHash'], '--if-document', doc['openToken'])
        ref = edit['workingRef']
        client = Client(MCP, env=dict(os.environ, C1_MCP_PROFILE='composition'), timeout=150)
        log('environment', session=str(base / 'keystone'), source=source, rawSHA256=source_sha, cliSHA256=sha(CLI), mcpSHA256=sha(MCP), contract=contract['version'])
        tool('geometry_set', {'workingRef':ref, 'ifGeometryState':source['geometryStateHash'], 'keystone':{'vertical':10}, 'dryRun':True}, error='invalid-request')
        # Each control's boundaries are exercised independently, so combined extreme
        # perspective does not manufacture an empty canvas unrelated to control range.
        cases = [('amount', 10), ('amount', 120), ('vertical', -75), ('vertical', 75),
                 ('horizontal', -75), ('horizontal', 75), ('skew', -45), ('skew', 45),
                 ('aspect', -50), ('aspect', 100), ('vertical', 12.5), ('horizontal', -8.25), ('skew', 3.5)]
        names = ['amount', 'vertical', 'horizontal', 'skew', 'aspect']
        for index, (name, value) in enumerate(cases):
            current = cli('get', ref)
            if index % 2:
                changed = tool('geometry_set', {'workingRef':ref, 'ifGeometryState':current['geometryStateHash'], 'keystone':{name:value}})
            else:
                changed = cli('geometry', 'set', ref, '--if-geometry-state', current['geometryStateHash'], f'--keystone-{name}={value}')
            expected = list(baseline['keystone']); expected[names.index(name)] = value
            assert all(abs(a-b) <= .001 for a, b in zip(changed['after']['keystone'], expected)), changed
            assert cli('get', ref)['stateHash'] == source['stateHash']
            assert len(cli('variants', 'list')) == 1
            restored = tool('geometry_restore', {'workingRef':ref, 'ifGeometryState':changed['geometryStateHash']})
            assert restored['after']['keystone'] == baseline['keystone']
            assert restored['after']['crop'] == baseline['crop']
            log('control-passed', case=f'{name}={value}', changed=changed, restored=restored)
        current = cli('get', ref)
        before_preview = tool('preview', {'ref':ref, 'outputDir':str(evidence / 'before')})
        patch = {'amount':80, 'vertical':12.5, 'horizontal':-8, 'skew':3, 'aspect':10}
        changed = tool('geometry_set', {'workingRef':ref, 'ifGeometryState':current['geometryStateHash'], 'keystone':patch, 'rotation':2, 'aspectRatio':1.5})
        tool('geometry_set', {'workingRef':ref, 'ifGeometryState':current['geometryStateHash'], 'keystone':{'vertical':0}}, error='state-changed')
        after_preview = tool('preview', {'ref':ref, 'outputDir':str(evidence / 'after')})
        assert before_preview['pixelSha256'] != after_preview['pixelSha256']
        assert abs(after_preview['width']/after_preview['height']-1.5) < .003
        difference = tool('diff', {'ref1':ref})
        assert all('keystone.'+name in difference['geometryDiff'] for name in names)
        operation = tool('operation_status', {'operationId':changed['operationId']})
        assert operation['requestedGeometry']['keystone'] == patch
        assert operation['beforeGeometry'] == current['geometry']
        assert operation['status'] == 'succeeded'
        partial = cli('geometry', 'set', ref, '--if-geometry-state', changed['geometryStateHash'], '--keystone-vertical=0')
        assert partial['after']['keystone'] == [80,0,-8,3,10]
        restored = cli('geometry', 'restore', ref, '--if-geometry-state', partial['geometryStateHash'])
        assert restored['after']['crop'] == baseline['crop']
        assert restored['after']['rotation'] == baseline['rotation']
        assert restored['after']['keystone'] == baseline['keystone']
        assert not tool('diff', {'ref1':ref})['geometryDiff']
        restored_preview = tool('preview', {'ref':ref, 'outputDir':str(evidence / 'restored')})
        preview_error = restored_preview_error(before_preview, restored_preview)
        assert sha(raw) == source_sha and sha(fixture) == source_sha
        assert len(cli('variants', 'list')) == 1
        log('combined-passed', changed=changed, partial=partial, restored=restored, diff=difference, operation=operation, beforePreview=before_preview, afterPreview=after_preview, restoredPreview=restored_preview, restoredPreviewError=preview_error, rawSHA256=sha(raw))
        success = True
    finally:
        if client: client.close()
        if success:
            apple('close current document')
        else:
            log('failure-retained', session=str(base / 'keystone'))


if __name__ == '__main__':
    main()
