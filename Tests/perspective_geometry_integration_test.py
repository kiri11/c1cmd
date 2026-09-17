#!/usr/bin/env python3
"""Existing perspective and movement CLI/MCP qualification using a copied RAW and owned Session.

Requires zero open documents, C1_TEST_RAW_FIXTURE and optional C1_PERSPECTIVE_EVIDENCE.
Native fixture writes are journaled; any failure stops without automatic retry.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import uuid

from contract_test import Client, validate_response

ROOT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get('C1_TEST_BIN', ROOT / '.build/debug/c1'))
MCP = Path(os.environ.get('C1_TEST_MCP_BIN', ROOT / '.build/debug/c1-mcp'))
RAW = Path(os.environ['C1_TEST_RAW_FIXTURE'])
EVIDENCE = Path(os.environ.get('C1_PERSPECTIVE_EVIDENCE', tempfile.mkdtemp(prefix='c1-perspective-evidence-')))
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
    result = subprocess.run([str(CLI), *map(str, args), '--format', 'json'],
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


def pixels(path):
    # macOS image decoding with no third-party Python packages. BMP rows are BGR.
    with tempfile.TemporaryDirectory(prefix='c1-lens-pixels-') as directory:
        out = Path(directory) / 'preview.bmp'
        subprocess.run(['sips', '-s', 'format', 'bmp', str(path), '--out', str(out)],
                       check=True, capture_output=True)
        data = out.read_bytes()
    offset = struct.unpack_from('<I', data, 10)[0]
    width, height = struct.unpack_from('<ii', data, 18)
    bits = struct.unpack_from('<H', data, 28)[0]
    compression = struct.unpack_from('<I', data, 30)[0]
    assert bits in (24, 32) and compression == 0, (bits, compression)
    stride = ((width * bits + 31) // 32) * 4
    def pixel(x, y):
        x, y = min(width-1, max(0, int(x))), min(abs(height)-1, max(0, int(y)))
        row = abs(height)-1-y if height > 0 else y
        pos = offset + row*stride + x*(bits//8)
        return data[pos:pos+3]
    return width, abs(height), pixel


def check_mapping(context, cropped):
    cw, ch, cp = pixels(context['outputPath'])
    pw, ph, pp = pixels(cropped['outputPath'])
    outer, inner = context['geometry']['crop'], cropped['geometry']['crop']
    errors = []
    # Sample corresponding locations away from the resampled JPEG edges.
    for iy in range(4, 77):
        for ix in range(4, 77):
            u, v = ix/80, iy/80
            x = inner['centerX']-inner['width']/2+u*inner['width']
            y = inner['centerY']+inner['height']/2-v*inner['height']
            px = (x-(outer['centerX']-outer['width']/2))/outer['width']*cw
            py = ((outer['centerY']+outer['height']/2)-y)/outer['height']*ch
            a, b = cp(px, py), pp(u*pw, v*ph)
            errors.extend(abs(x-y) for x, y in zip(a, b))
    mean = sum(errors)/len(errors)
    assert mean < 8, ('Preview/crop coordinate mismatch', mean)
    return {'meanAbsoluteChannelError': mean, 'threshold': 8, 'sampledPixels': len(errors)//3}


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
    result = client.tool(name, args)
    assert not result.get('isError'), result
    data = json.loads(result['content'][0]['text'])
    validate_response(data, contract['responses'][name], name)
    return data


def fixture_write(body):
    assert cli('doctor')['allChecksPassed']
    record = dict(binding, operationId=str(uuid.uuid4()), operationType='perspective-fixture',
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
    # amount, hidden, orientation, rotation, ratio, keystone, movement fixture
    cases = [
        (0, True, 0, 5, 1.5, [100,15,0,0,0], False),
        (0, True, 90, -5, .75, [100,0,-15,0,0], False),
        (50, False, 180, 5, 1.5, [75,10,-10,5,10], False),
        (100, True, 270, -5, .75, [100,-10,10,-5,-10], False),
        (100, True, 0, 45, 1.5, [100,10,5,0,0], True),
        (50, False, 90, -45, .75, [100,0,0,0,0], True),
        (100, True, 180, 5, 1.5, [100,0,0,0,0], True),
        (0, True, 270, -5, .75, [100,0,0,0,0], True),
    ]
    for index, (amount, hidden, orientation, angle, ratio, keystone, movements) in enumerate(cases):
        profile = 'Phase One 45mm TS f/3.5' if movements else original['geometry']['lensProfile']
        body = f'set lens profile of lens correction of v to "{profile}"\n'
        if movements:
            sign = 1 if index % 2 == 0 else -1
            body += f"""set tilt of lens correction of v to 2
set tilt direction of lens correction of v to {45 if sign == 1 else 225}
set shift of lens correction of v to 3
set shift direction of lens correction of v to {90 if sign == 1 else 270}
set shift x of lens correction of v to {2*sign}
set shift y of lens correction of v to {-2*sign}
"""
        for key,value in zip(['amount','vertical','horizontal','skew','aspect'],keystone):
            body += f'set keystone {key} of adjustments of v to {value}\n'
        fixture_write(body + f"""set distortion of lens correction of v to {amount}
set hide distorted areas of lens correction of v to {str(hidden).lower()}
set orientation of adjustments of v to {orientation}
set rotation of adjustments of v to 0
set crop of v to (maximum crop v apply false)""")
        before = cli('get', vid)
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
        if index < 4 or index >= 6:
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
        if index in (2, 6):
            current = cli('get', ref)
            patch = {'vertical': before['geometry']['keystone'][1] + 3,
                     'horizontal': before['geometry']['keystone'][2] - 2}
            corrected = tool('geometry_set', {'workingRef':ref, 'ifGeometryState':current['geometryStateHash'],
                                             'keystone':patch, 'rotation':2, 'aspectRatio':ratio})
            expected = list(before['geometry']['keystone'])
            expected[1], expected[2] = patch['vertical'], patch['horizontal']
            assert corrected['after']['keystone'] == expected
            for key in ['lensGeometry', 'lensProfile', 'hideDistortedAreas', 'orientation']:
                assert corrected['after'][key] == before['geometry'][key]
            rendered = tool('preview', {'ref':ref})
            assert abs(rendered['width']/rendered['height']-ratio) < .003
            restored = tool('geometry_restore', {'workingRef':ref, 'ifGeometryState':corrected['geometryStateHash']})
            assert restored['after']['keystone'] == before['geometry']['keystone']
            assert restored['after']['crop'] == before['geometry']['crop']
            assert cli('get', ref)['stateHash'] == before['stateHash']
            log('keystone-write', case=index, corrected=corrected, restored=restored, preview=rendered)
        assert cli('get', original['id']) == original
        log('case-passed', case=index)
    # Changed correction values invalidate an earlier geometry token.
    stale = cli('get', ref)
    fixture_write('set keystone vertical of adjustments of v to 2')
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
    log('failed', error=str(error))
    raise
finally:
    client.close()
