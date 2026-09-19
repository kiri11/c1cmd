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
            'noise reduction luminance':35,'noise reduction color':40},
            exposure=dict(mode='relative',value=.125),whiteBalance=dict(mode='preserve'),cropPolicy='per-photo')
        registered = recipe('register',dict(recipe=payload))
        identifier = registered['recipeId']
        request = dict(sourceRef=source['id'],recipeId=identifier,ifState=source['stateHash'],ifDocument=doc['openToken'])
        recipe('apply',request,ok=False)
        clone = cli('variant','clone',source['id'])
        current = cli('get',clone['workingRef'])
        verified = recipe('verify',dict(recipeId=identifier,workingRef=clone['workingRef'],ifDocument=doc['openToken'],ifState=current['stateHash']))
        assert verified['status'] == 'succeeded'
        cli('variant','delete',clone['workingRef'])
        client = Client(MCP,timeout=240)
        schema = json.loads(client.tool("schema")["content"][0]["text"])
        request.update(overrides={'clarity amount':7},exposure=dict(mode='absolute',value=.25),
                       whiteBalance=dict(mode='absolute',temperature=5200,tint=2),
                       ifGeometryState=source['geometryStateHash'],geometry=dict(aspectRatio=1.5),preview=True)
        result = client.tool('edit_apply',request)
        value = json.loads(result['content'][0]['text']); log('mcp-apply',value)
        assert not result.get('isError'), value
        assert value['status'] == 'succeeded'
        validate_response(value,schema['responses']['edit_apply'])
        observed = value['observed']
        assert observed['nativeSnapshots'][0]['values']['clarity amount'] == 7
        assert abs(observed['adjustments']['exposure']-.25) < .001
        assert abs(observed['adjustments']['temperature']-5200) < 1
        assert abs(observed['geometry']['crop']['width']/observed['geometry']['crop']['height']-1.5) < .002
        status = recipe('status',dict(compoundId=value['compoundId']))
        assert status == value
        assert len(cli('variants','list')) == 1, 'Compound edits must not duplicate variants'
        assert sha(raw) == sha(fixture) == original
        log('passed',dict(rawSHA256=original,cliSHA256=sha(CLI),mcpSHA256=sha(MCP),session=str(base/'recipes')))
        apple('close current document')
    finally:
        if client: client.close()
        # Failed fixtures and unresolved operations remain available for inspection.


if __name__ == '__main__':
    main()
