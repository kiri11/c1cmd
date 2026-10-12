#!/usr/bin/env python3
"""Corrected-lens CLI/MCP qualification using a copied RAW and owned Session.

Requires zero open documents, C1_TEST_RAW_FIXTURE and optional C1_LENS_EVIDENCE.
Native fixture writes are journaled; any failure stops without automatic retry.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

from contract_test import Client, validate_response, complete, complete_args
from preview_mapping import check_mapping
from catalog_integration_test import close_retained

ROOT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get('C1_TEST_BIN', ROOT / '.build/debug/c1'))
MCP = Path(os.environ.get('C1_TEST_MCP_BIN', ROOT / '.build/debug/c1-mcp'))
RAW = Path(os.environ['C1_TEST_RAW_FIXTURE'])
EVIDENCE = Path(os.environ.get('C1_LENS_EVIDENCE', tempfile.mkdtemp(prefix='c1-lens-evidence-')))
EVIDENCE.mkdir(parents=True, exist_ok=True)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def log(event, **values):
    with (EVIDENCE / 'events.jsonl').open('a') as stream:
        stream.write(json.dumps(dict(event=event, **values)) + '\n')
        stream.flush()
        os.fsync(stream.fileno())
    print(event, values.get('case', ''), flush=True)


def apple(body):
    result = subprocess.run(['osascript', '-s', 's', '-e',
        'tell application "/Applications/Capture One.app"\n' + body + '\nend tell'],
        capture_output=True, text=True, timeout=150)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def cli(*args, error=None):
    result = subprocess.run([str(CLI), *complete(args), '--format', 'json'],
                            capture_output=True, text=True, timeout=150)
    payload = result.stderr if result.returncode else result.stdout
    try:
        data = json.loads(payload)
    except json.JSONDecodeError:
        raise AssertionError((args, result.returncode, payload)) from None
    if error:
        assert result.returncode and data['error']['code'] == error, data
    else:
        assert result.returncode == 0, data
    return data


assert apple('return count of documents') == '0', 'Close documents before qualification'
assert json.loads(apple('return version')) == '16.8.5.30'
parent = ROOT / '.build/lens-qualification'
parent.mkdir(parents=True, exist_ok=True)
base = Path(tempfile.mkdtemp(prefix='live-', dir=parent))
apple(f'make new document with properties {{name:"lens", kind:session, path:"{base}"}}')
session = base / 'lens'
fixture = session / 'Capture' / RAW.name
original_sha = sha(RAW)
shutil.copy2(RAW, fixture)
apple('set current collection of current document to collection "Capture" of current document')
for _ in range(40):
    variants = cli('variants', 'list')
    if variants:
        break
    time.sleep(.5)
health = cli('doctor')
assert health['allChecksPassed'] and health['writesEnabled'] and health['exactBuildMatched']
document = cli('doc', 'info')
original = cli('get', variants[0]['id'])
clone = cli('variant', 'clone', original['id'])
vid = clone['cloneVariantId']
journal = session / '.c1/journal.jsonl'
binding = json.loads(journal.read_text().splitlines()[0])
contract = cli('schema')
client = Client(MCP, timeout=150)
log('environment', session=str(session), document=document, original=original, clone=clone,
    rawSHA256=original_sha, cliSHA256=sha(CLI), mcpSHA256=sha(MCP))


def tool(name, args):
    result = client.tool(name, complete_args(name, args))
    assert not result.get('isError'), result
    data = json.loads(result['content'][0]['text'])
    validate_response(data, contract['responses'][name], name)
    return data


def fixture_write(body):
    assert cli('doctor')['allChecksPassed']
    record = dict(binding, operationId=str(uuid.uuid4()), operationType='lens-fixture',
                  nativeVariantId=vid, workingRef=clone['workingRef'], status='pending')
    def append():
        with journal.open('a') as stream:
            stream.write(json.dumps(record)+'\n'); stream.flush(); os.fsync(stream.fileno())
    append()
    log('fixture-pending', operationId=record['operationId'], script=body)
    try:
        apple(f'set v to variant id "{vid}" of current document\n'+body)
        record['status'] = 'succeeded'; append()
    except BaseException:
        # Pending stays unresolved. Never dispatch another mutation after failure.
        raise


try:
    cases = [(50, True, 0, 5, 1.5), (100, True, 90, -5, .75),
             (100, False, 180, 5, 1.5), (50, False, 270, -5, .75),
             (100, True, 0, 45, 1.5), (100, True, 90, -45, .75)]
    for index, (amount, hidden, orientation, angle, ratio) in enumerate(cases):
        fixture_write(f'''set distortion of lens correction of v to {amount}
set hide distorted areas of lens correction of v to {str(hidden).lower()}
set orientation of adjustments of v to {orientation}
set rotation of adjustments of v to 0
set crop of v to (maximum crop v apply false)''')
        before = cli('get', vid)
        if index == 0:
            # Deliberately request an off-center full-size stored crop on the
            # owned clone. Observe native normalization; never alter lens context
            # to make an otherwise rejected explicit rectangle pass.
            baseline = before
            rect = dict(before['geometry']['crop'])
            rect['centerX'] += rect['width'] * .05
            fixture_write('set crop of v to {' + ','.join(str(rect[k]) for k in
                          ['centerX', 'centerY', 'width', 'height']) + '}')
            stored = cli('get', vid)
            for key in ['lensGeometry', 'lensProfile', 'hideDistortedAreas', 'keystone', 'orientation', 'rotation']:
                assert stored['geometry'][key] == baseline['geometry'][key], key
            spec = importlib.util.spec_from_file_location('contained_crop', ROOT / 'scripts/propose-contained-crop.py')
            planner = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(planner)
            proposal = planner.plan(stored['geometry']['crop'], stored['geometry'])
            assert proposal['bounds'] == stored['geometryUsableBounds'], proposal
            log('stored-off-center-probe', requested=rect, observed=stored, proposal=proposal,
                nativeNormalized=rect != stored['geometry']['crop'])
            # This is fixture setup restoration after a completed read, not an
            # automatic retry/undo of an uncertain c1 operation.
            original_crop = baseline['geometry']['crop']
            fixture_write('set crop of v to {' + ','.join(str(original_crop[k]) for k in
                          ['centerX', 'centerY', 'width', 'height']) + '}')
            before = cli('get', vid)
            assert before['geometry'] == baseline['geometry']
        assert not before.get('geometryUnavailableReason'), before
        assert before['geometryUsableBounds'] == before['geometry']['maximumCrop']
        edit = tool('variant_edit', {'sourceRef': vid, 'ifDocument': document['openToken'],
                    'ifState': before['stateHash'], 'ifGeometryState': before['geometryStateHash']})
        ref = edit['workingRef']
        assert len(cli('variants', 'list')) == 2
        cli('geometry', 'set', ref, '--if-geometry-state', before['geometryStateHash'],
            f'--rotation={angle}', '--aspect-ratio', ratio, '--dry-run', error='invalid-request')
        result = tool('geometry_set', {'workingRef': ref, 'ifGeometryState': before['geometryStateHash'],
                                      'rotation': angle, 'aspectRatio': ratio})
        after = cli('get', ref)
        assert after['stateHash'] == before['stateHash']
        for key in ['lensGeometry', 'lensProfile', 'hideDistortedAreas', 'keystone', 'orientation']:
            assert after['geometry'][key] == before['geometry'][key], key
        assert abs(after['geometry']['rotation']-angle) < .001
        preview = tool('preview', {'ref': ref})
        assert abs(preview['width']/preview['height']-ratio) < .003
        operation = tool('operation_status', {'operationId': result['operationId']})
        assert operation['requestedGeometry']['rotation'] == angle and operation['status'] == 'succeeded'
        assert all(abs(operation['intendedGeometry']['crop'][key]-result['after']['crop'][key]) <= 2
                   for key in ['centerX','centerY','width','height']), operation
        log('rotated-ratio', case=index, before=before, result=result, preview=preview)
        if index < 4:
            context = tool('preview', {'ref': ref, 'fullFrame': True})
            assert len(cli('variants', 'list')) == 2, 'Context clone leaked'
            assert cli('get', ref)['geometryStateHash'] == after['geometryStateHash']
            bounds = after['geometryUsableBounds']
            crop = dict(centerX=round(bounds['centerX']+bounds['width']*.09),
                        centerY=round(bounds['centerY']-bounds['height']*.07),
                        width=int(bounds['width']*.5), height=int(bounds['height']*.5))
            applied = cli('geometry', 'set', ref, '--if-geometry-state', after['geometryStateHash'],
                          '--crop', ','.join(str(crop[k]) for k in ['centerX','centerY','width','height']))
            assert applied['after']['crop'] == crop
            cropped = cli('preview', ref)
            metrics = check_mapping(context, cropped)
            log('preview-mapping', case=index, context=context, cropped=cropped, metrics=metrics)
        if index == 1:
            # Corrected vertical canvas: the anchored 3:4 fit is planned in maximumCrop at the
            # current rotation and journaled as an explicit crop; a new rotation is refused.
            keys = ['centerX', 'centerY', 'width', 'height']
            fresh = cli('get', ref)
            bounds = fresh['geometryUsableBounds']
            cli('geometry', 'set', ref, '--if-geometry-state', fresh['geometryStateHash'], '--rotation=-3',
                '--aspect-ratio', .75, '--anchor', '0.5,0', error='invalid-request')
            dry = cli('geometry', 'set', ref, '--if-geometry-state', fresh['geometryStateHash'],
                      '--aspect-ratio', .75, '--anchor', '0.5,0', '--dry-run')
            assert dry['isDryRun'] and dry['anchoredCrop'] == dry['after']['crop'], dry
            top = tool('geometry_set', {'workingRef': ref, 'ifGeometryState': fresh['geometryStateHash'],
                                       'aspectRatio': .75, 'anchor': {'x': .5, 'y': 0}})
            assert all(abs(top['after']['crop'][k]-dry['anchoredCrop'][k]) <= 2 for k in keys), (dry, top)
            assert abs(top['after']['crop']['centerY']+top['after']['crop']['height']/2
                       - (bounds['centerY']+bounds['height']/2)) <= 3, ('top-aligned in maximumCrop', bounds, top)
            assert top['after']['lensGeometry'] == before['geometry']['lensGeometry']
            operation = tool('operation_status', {'operationId': top['operationId']})
            assert operation['status'] == 'succeeded' and operation['requestedGeometry'].get('aspectRatio') is None
            assert operation['requestedGeometry']['crop'] == dry['anchoredCrop'], operation
            log('anchored-corrected', case=index, bounds=bounds, dryRun=dry, result=top, operation=operation)
        current = cli('get', ref)
        diff = tool('diff', {'ref1': ref})
        assert diff['geometryDiff']
        restored = tool('geometry_restore', {'workingRef': ref, 'ifGeometryState': current['geometryStateHash']})
        assert restored['after']['crop'] == before['geometry']['crop']
        assert restored['after']['rotation'] == before['geometry']['rotation']
        assert restored['after']['lensGeometry'] == before['geometry']['lensGeometry']
        if index == 0:
            rotated = tool('geometry_set', {'workingRef': ref, 'ifGeometryState': restored['geometryStateHash'], 'rotation': 2})
            assert abs(rotated['after']['rotation']-2) < .001
            assert rotated['after']['lensGeometry'] == before['geometry']['lensGeometry']
            log('rotation-only', result=rotated, preview=tool('preview', {'ref': ref}))
            tool('geometry_restore', {'workingRef': ref, 'ifGeometryState': rotated['geometryStateHash']})
        assert cli('get', original['id']) == original
        log('case-passed', case=index)
    # Orientation on the lens-corrected clone. The corrected bounds exist only after the native
    # orientation, so dry runs and anchors are refused and dispatch nothing; each step reads back,
    # keeps the lens context, crops inside the corrected canvas, previews in that shape, and restores.
    fixture_write('''set distortion of lens correction of v to 100
set hide distorted areas of lens correction of v to true
set orientation of adjustments of v to 0
set rotation of adjustments of v to 0
set crop of v to (maximum crop v apply false)''')
    before = cli('get', vid)
    assert before['geometry']['orientation'] == 0 and before['geometry']['lensGeometry'][0] == 100, before['geometry']
    ref = tool('variant_edit', {'sourceRef': vid, 'ifDocument': document['openToken'], 'ifState': before['stateHash'],
               'ifGeometryState': before['geometryStateHash']})['workingRef']
    token = before['geometryStateHash']
    for refused in (['--orientation', 90, '--dry-run'], ['--orientation', 90, '--aspect-ratio', .75, '--dry-run'],
                    ['--orientation', 90, '--aspect-ratio', .75, '--anchor', '0.5,0']):
        cli('geometry', 'set', ref, '--if-geometry-state', token, *refused, error='invalid-request')
    unchanged = cli('get', ref)
    assert (unchanged['geometryStateHash'], unchanged['stateHash']) == (token, before['stateHash']), 'refused orientation requests dispatch nothing'
    previous = before
    for value, ratio in ((90, None), (180, 1.5), (0, None), (270, .75)):
        result = tool('geometry_set', dict({'workingRef': ref, 'ifGeometryState': previous['geometryStateHash'],
                                            'orientation': value}, **({'aspectRatio': ratio} if ratio else {})))
        after = cli('get', ref)
        g = after['geometry']
        assert g['orientation'] == value == result['after']['orientation'], (value, result, g)
        assert after['geometryStateHash'] == result['geometryStateHash'] and after['stateHash'] == before['stateHash'], (value, result)
        for key in ['lensGeometry', 'lensProfile', 'hideDistortedAreas', 'keystone', 'rotation']:
            assert g[key] == before['geometry'][key], (value, key)
        bounds = after['geometryUsableBounds']
        portrait = value in (90, 270)
        assert bounds == g['maximumCrop'] and (bounds['height'] > bounds['width']) == portrait, (value, bounds)
        assert all(abs(g['crop'][c] - bounds[c]) + g['crop'][s] / 2 <= bounds[s] / 2 + 2
                   for c, s in (('centerX', 'width'), ('centerY', 'height'))), ('crop inside corrected canvas', value, g)
        preview = tool('preview', {'ref': ref})
        assert (preview['height'] > preview['width']) == portrait, (value, preview)
        if ratio:
            assert abs(g['crop']['width'] / g['crop']['height'] - ratio) < .003 and abs(preview['width'] / preview['height'] - ratio) < .003, (value, g, preview)
        operation = tool('operation_status', {'operationId': result['operationId']})
        assert operation['status'] == 'succeeded' and operation['requestedGeometry']['orientation'] == value, operation
        assert operation['requestedGeometry'].get('aspectRatio') == ratio, operation
        log('corrected-orientation', case=value, result=result, bounds=bounds, preview=preview, operation=operation)
        previous = after
    restored = tool('geometry_restore', {'workingRef': ref, 'ifGeometryState': previous['geometryStateHash']})
    assert restored['after']['orientation'] == 0 and restored['after']['crop'] == before['geometry']['crop'], restored
    assert restored['after']['lensGeometry'] == before['geometry']['lensGeometry'], restored
    assert cli('get', ref)['geometryStateHash'] == before['geometryStateHash'], 'restore returns the corrected baseline'
    preview = tool('preview', {'ref': ref})
    assert preview['width'] > preview['height'], preview
    log('corrected-orientation-restored', result=restored, preview=preview)
    # Changed correction values invalidate an earlier geometry token.
    stale = cli('get', ref)
    fixture_write('set distortion of lens correction of v to 50')
    cli('geometry','set',ref,'--if-geometry-state',stale['geometryStateHash'],'--aspect-ratio',1.5,error='state-changed')
    # Crop outside the image stays blocked; rejection dispatches no setters.
    fixture_write('set crop outside image of v to true')
    blocked = cli('get', ref)
    assert blocked.get('geometryUnavailableReason')
    cli('geometry','set',ref,'--if-geometry-state',blocked['geometryStateHash'],'--aspect-ratio',1.5,error='invalid-request')
    assert cli('get',ref) == blocked
    assert sha(RAW) == original_sha and sha(fixture) == original_sha
    cli('variant','delete',clone['workingRef'])
    assert cli('get',original['id']) == original
    shutil.copy2(journal,EVIDENCE/'journal.jsonl')
    apple('close current document')
    log('passed', cases=len(cases), rawSHA256=sha(fixture), originalUnchanged=True)
except BaseException as error:
    log('failed', error=str(error), document=close_retained(session))
    raise
finally:
    client.close()
