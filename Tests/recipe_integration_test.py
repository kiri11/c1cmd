#!/usr/bin/env python3
"""Recipe payload verification and compound CLI/MCP edits on an owned RAW copy."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from catalog_integration_test import apple, sha, CLI, MCP, ROOT
from contract_test import Client, validate_response


def main():
    raw = Path(os.environ['C1_TEST_RAW_FIXTURE']).resolve()
    original = sha(raw)
    assert apple('return count of documents') == '0', 'Close documents before recipe qualification'
    base = Path(tempfile.mkdtemp(prefix='c1-recipes-', dir=str(ROOT / '.build')))
    evidence = Path(os.environ.get('C1_RECIPE_EVIDENCE', base / 'evidence'))
    evidence.mkdir(parents=True, exist_ok=True)
    events = []
    def log(name, value):
        events.append(dict(event=name, value=value))
        (evidence/'results.json').write_text(json.dumps(events, indent=2)+'\n')
        print(name, flush=True)
    def cli(*args, ok=True):
        r = subprocess.run([str(CLI), *map(str,args), '--format','json'], capture_output=True,text=True,timeout=240)
        value = json.loads(r.stdout or r.stderr)
        log('cli',dict(args=list(map(str,args)),code=r.returncode,result=value))
        assert (r.returncode == 0) == ok, value
        return value
    def recipe(action, args, ok=True):
        path = base / ('request-' + str(len(events)) + '.json')
        path.write_text(json.dumps(args))
        return cli('recipe',action,'--file',path,ok=ok)
    client = None
    try:
        apple(f'make new document with properties {{name:"recipes", kind:session, path:{json.dumps(str(base))}}}')
        fixture = base/'recipes/Capture'/raw.name
        shutil.copy2(raw,fixture)
        apple('set current collection of current document to collection "Capture" of current document')
        for _ in range(40):
            variants = cli('variants','list')
            if variants: break
            time.sleep(.25)
        assert len(variants) == 1
        doctor = cli('doctor')
        assert doctor['allChecksPassed'] and doctor['writesEnabled'] and doctor['exactBuildMatched']
        source = cli('get',variants[0]['id'])
        doc = cli('doc','info')
        capture = recipe('capture',dict(ref=source['id'],ifDocument=doc['openToken'],ifState=source['stateHash']))
        assert capture['bundle']['coverage']['maskPixels'] == 'unsupported'
        assert sha(Path(capture['bundle']['preview']['outputPath'])) == capture['bundle']['previewFileSha256']
        payload = dict(version=1,referenceId=capture['referenceId'],settings={
            'brightness':4,'contrast':3,'saturation':2,'highlight adjustment':5,'shadow recovery':6,
            'white recovery':4,'black recovery':3,'clarity amount':5,'clarity structure':2,
            'sharpening amount':170,'sharpening radius':.8,'sharpening threshold':1,
            'noise reduction luminance':35,'noise reduction color':40,
            'rgb curve':[0,0,50,55,100,100], 'luma curve':[0,0,50,52,100,100],
            'red curve':[0,0,50,53,100,100], 'green curve':[0,0,50,54,100,100],
            'blue curve':[0,0,50,56,100,100],
            'film grain type':'silver rich','film grain impact':25,'film grain granularity':30,
            'vignetting method':'circular','vignetting amount':-.5},
            exposure=dict(mode='relative',value=.125),whiteBalance=dict(mode='preserve'),cropPolicy='per-photo')
        registered = recipe('register',dict(recipe=payload))
        identifier = registered['recipeId']
        request = dict(sourceRef=source['id'],recipeId=identifier,ifState=source['stateHash'],ifDocument=doc['openToken'])
        recipe('apply',request,ok=False)
        clone = cli('variant','clone',source['id'])
        current = cli('get',clone['workingRef'])
        verified = recipe('verify',dict(recipeId=identifier,workingRef=clone['workingRef'],ifDocument=doc['openToken'],ifState=current['stateHash']))
        assert verified['status'] == 'succeeded'
        assert verified['resultBundle']['preview']['outputPath']
        assert verified['resultBundle']['provenance']['mode'] == 'recipe-verification'
        cli('variant','delete',clone['workingRef'])
        client = Client(MCP,timeout=240)
        schema = json.loads(client.tool("schema")["content"][0]["text"])
        request.update(overrides={'clarity amount':7,'rgb curve':[0,0,50,57,100,100],'film grain type':'soft','vignetting method':'circular on crop'},exposure=dict(mode='absolute',value=.25),
                       whiteBalance=dict(mode='absolute',temperature=5200,tint=2),
                       ifGeometryState=source['geometryStateHash'],geometry=dict(aspectRatio=1.5),preview=True)
        result = client.tool('edit_apply',request)
        value = json.loads(result['content'][0]['text']); log('mcp-apply',value)
        assert not result.get('isError'), value
        assert value['status'] == 'succeeded'
        validate_response(value,schema['responses']['edit_apply'])
        observed = value['observed']
        bundle = value['resultBundle']
        assert bundle['observed'] == observed
        provenance = bundle['provenance']
        assert provenance['recipeId'] == identifier and provenance['recipe'] == payload
        assert provenance['referenceId'] == capture['referenceId']
        assert provenance['verification']['compoundId'] == verified['compoundId']
        assert provenance['nativeVariantId'] == source['id']
        assert provenance['initialHashes']['stateHash'] == source['stateHash']
        assert provenance['finalHashes']['stateHash'] == observed['stateHash']
        assert provenance['effectivePolicy']['settings']['clarity amount'] == 7
        assert provenance['operations'] == [dict(step=s['step'],operationId=s['result']['operationId'])
            for s in value['completed'] if 'operationId' in s.get('result',{})]
        exposure = bundle['diff']['adjustments']['exposure']
        assert exposure['before'] == source['adjustments']['exposure']
        assert exposure['after'] == observed['adjustments']['exposure']
        assert abs(exposure['delta']-(exposure['after']-exposure['before'])) < .000001
        assert bundle['diff']['nativeAdjustments']['clarity amount']['after'] == 7
        assert bundle['diff']['metadata'] == {}
        native = observed['nativeSnapshots'][0]['values']
        effective = dict(payload['settings'],**request['overrides'])
        for key, wanted in effective.items():
            actual = native[key]
            if isinstance(wanted,list):
                assert len(actual) == len(wanted) and all(abs(a-b)<.0001 for a,b in zip(actual,wanted)), (key,actual)
            elif isinstance(wanted,str): assert actual == wanted, (key,actual)
            else: assert abs(actual-wanted)<.0001, (key,actual)
        for key in ['rgb curve','film grain type','vignetting method']:
            assert bundle['diff']['nativeAdjustments'][key]['after'] == native[key]
        assert bundle['coverage']['geometry'] == 'compared'
        assert bundle['coverage']['maskPixels'] == 'unsupported'
        assert bundle['coverage']['atomicSnapshot'] is False
        assert bundle['preview'] == next(s['result'] for s in value['completed'] if s['step'] == 'preview')
        assert Path(bundle['preview']['outputPath']).is_file()
        assert observed['nativeSnapshots'][0]['values']['clarity amount'] == 7
        assert abs(observed['adjustments']['exposure']-.25) < .001
        assert abs(observed['adjustments']['temperature']-5200) < 1
        assert abs(observed['geometry']['crop']['width']/observed['geometry']['crop']['height']-1.5) < .002
        status = recipe('status',dict(compoundId=value['compoundId']))
        assert status == value
        # A sparse recipe must preserve non-default curves, grain, vignette and all policies.
        sparse = dict(version=1,referenceId=capture['referenceId'],settings={'clarity amount':8},
            exposure=dict(mode='preserve'),whiteBalance=dict(mode='preserve'),cropPolicy='preserve')
        sparse_id = recipe('register',dict(recipe=sparse))['recipeId']
        clone = cli('variant','clone',source['id'])
        current = cli('get',clone['workingRef'])
        sparse_verified = recipe('verify',dict(recipeId=sparse_id,workingRef=clone['workingRef'],ifDocument=doc['openToken'],ifState=current['stateHash']))
        assert sparse_verified['status'] == 'succeeded'
        cli('variant','delete',clone['workingRef'])
        sparse_applied = recipe('apply',dict(recipeId=sparse_id,sourceRef=source['id'],ifDocument=doc['openToken'],ifState=observed['stateHash']))
        assert sparse_applied['status'] == 'succeeded'
        validate_response(sparse_applied,schema['responses']['edit_apply'])
        sparse_bundle = sparse_applied['resultBundle']
        assert set(sparse_bundle['diff']['nativeAdjustments']) == {'clarity amount'}
        for group in ['adjustments','geometry','metadata']: assert sparse_bundle['diff'][group] == {}
        for key, before in native.items():
            if key != 'clarity amount': assert sparse_bundle['observed']['nativeSnapshots'][0]['values'][key] == before, key
        assert len(cli('variants','list')) == 1, 'Compound edits must not duplicate variants'
        assert sha(raw) == sha(fixture) == original
        log('passed',dict(rawSHA256=original,cliSHA256=sha(CLI),mcpSHA256=sha(MCP),session=str(base/'recipes')))
        apple('close current document')
    finally:
        if client: client.close()
        # Failed fixtures and unresolved operations remain available for inspection.


if __name__ == '__main__':
    main()
