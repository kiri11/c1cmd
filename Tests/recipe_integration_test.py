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
    group = os.environ.get("C1_RECIPE_TEST_GROUP", "all")
    assert group in ("all", "scopes")
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
        # Native indexed inventories and deletion readback must retain layer context.
        layer_clone = cli('variant','clone',source['id'])['workingRef']
        layer_state = cli('get',layer_clone,'--native-targets','[{"scope":"adjustments"}]')['nativeSnapshots'][0]
        layer_result = cli('native','action',layer_clone,'layer.create','--scope','adjustments','--if-native-state',layer_state['nativeStateHash'],'--json',json.dumps(dict(name='Scoped inventory fixture',kind='adjustment')))
        layer_index = len(layer_result['after']['layers'])
        for _ in range(2):
            layer_state = cli('get',layer_clone,'--native-targets',json.dumps([dict(scope='adjustments',layer=layer_index)]))['nativeSnapshots'][0]
            cli('native','action',layer_clone,'color.create','--scope','adjustments','--layer',layer_index,'--if-native-state',layer_state['nativeStateHash'])
        band_state = cli('get',layer_clone,'--native-targets',json.dumps([dict(scope='advancedColor',layer=layer_index,element=1)]))['nativeSnapshots'][0]
        assert band_state['advancedColorCount'] == 2
        deleted = cli('native','action',layer_clone,'color.delete','--scope','advancedColor','--layer',layer_index,'--element',1,'--if-native-state',band_state['nativeStateHash'])
        assert deleted['after']['target']['layer'] == layer_index and deleted['after']['advancedColorCount'] == 1
        cli('variant','delete',layer_clone)
        # Seed one advanced band to qualify explicit replacement of existing inventory.
        edit = cli('variant','edit',source['id'],'--if-document',doc['openToken'],'--if-state',source['stateHash'])
        native = cli('get',edit['workingRef'],'--native-targets','[{"scope":"adjustments"}]')['nativeSnapshots'][0]
        cli('native','action',edit['workingRef'],'color.create','--scope','adjustments','--if-native-state',native['nativeStateHash'])
        template = cli('get',edit['workingRef'],'--native-targets','[{"scope":"advancedColor","element":1}]')['nativeSnapshots'][0]['values']
        capture = recipe('capture',dict(ref=source['id'],ifDocument=doc['openToken'],ifState=source['stateHash']))
        assert capture['bundle']['coverage']['maskPixels'] == 'unsupported'
        assert sha(Path(capture['bundle']['preview']['outputPath'])) == capture['bundle']['previewFileSha256']
        client = Client(MCP,timeout=240)
        schema = json.loads(client.tool("schema")["content"][0]["text"])
        if group == "all":
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
        scoped_settings = {}
        for wheel in ['master','shadow','midtone','highlight']:
            scoped_settings[f'color balance {wheel} hue'] = 237
            scoped_settings[f'color balance {wheel} saturation'] = .2
            if wheel != 'master': scoped_settings[f'color balance {wheel} lightness'] = .1
        scoped = dict(version=2,referenceId=capture['referenceId'],settings=scoped_settings,
            exposure=dict(mode='preserve'),whiteBalance=dict(mode='preserve'),cropPolicy='preserve',scopes=dict(
                camera=dict(cameraModel=source['metadata']['camera'],settings={'film curve':'Linear Response','color profile':capture['bundle']['scopedNative']['camera']['color profile']}),
                lens=dict(cameraModel=source['metadata']['camera'],lensModel=source['metadata']['lens'],geometryPolicy='preserve-crop',settings={'light falloff':15,'sharpness falloff':10}),
                basicColor=[dict(index=2,name=capture['bundle']['scopedNative']['basicColor'][1]['name'],settings={'hue change':5,'saturation change':3})],
                advancedColor=dict(mode='replace',bands=[dict(template,**{'hue change':3}),dict(template,**{'hue change':7})])))
        def verify_scoped(payload):
            rid = recipe('register',dict(recipe=payload))['recipeId']
            clone = cli('variant','clone',source['id'])
            current = cli('get',clone['workingRef'])
            checked = recipe('verify',dict(recipeId=rid,workingRef=clone['workingRef'],ifDocument=doc['openToken'],ifState=current['stateHash']))
            assert checked['status'] == 'succeeded'
            validate_response(checked,schema['responses']['recipe_verify'])
            cli('variant','delete',clone['workingRef'])
            return rid
        scoped_id = verify_scoped(scoped)
        current = cli('get',source['id'])
        applied = client.tool('edit_apply',dict(recipeId=scoped_id,sourceRef=source['id'],ifDocument=doc['openToken'],ifState=current['stateHash'],ifGeometryState=current['geometryStateHash'],preview=True))
        applied_value = json.loads(applied['content'][0]['text']); log('mcp-scoped-apply',applied_value)
        assert not applied.get('isError'), applied_value
        validate_response(applied_value,schema['responses']['edit_apply'])
        scopes_seen = applied_value['resultBundle']['scopedNative']['observed']
        assert scopes_seen['camera']['film curve'] == 'Linear Response'
        assert scopes_seen['lens']['light falloff'] == 15
        assert scopes_seen['basicColor'][1]['hue change'] == 5
        assert [b['hue change'] for b in scopes_seen['advancedColor']] == [3,7]
        for index, row in enumerate(scopes_seen['basicColor']):
            if index != 1: assert row == capture['bundle']['scopedNative']['basicColor'][index]
        steps = [s['step'] for s in applied_value['completed']]
        assert 'scope-advanced-delete-1' in steps and 'scope-advanced-set-2' in steps
        assert recipe('status',dict(compoundId=applied_value['compoundId'])) == applied_value
        # Version 2 with no scoped changes must preserve the populated scoped state.
        preserve = dict(version=2,referenceId=capture['referenceId'],settings={'clarity amount':9},
            exposure=dict(mode='preserve'),whiteBalance=dict(mode='preserve'),cropPolicy='preserve')
        preserve_id = verify_scoped(preserve)
        current = cli('get',source['id'])
        preserved = recipe('apply',dict(recipeId=preserve_id,sourceRef=source['id'],ifDocument=doc['openToken'],ifState=current['stateHash']))
        assert preserved['status'] == 'succeeded'
        assert preserved['scopedObserved'] == scopes_seen
        # Lens-induced crop changes and a later explicit geometry step use separate policies/tokens.
        lens_geometry = dict(preserve,settings={},cropPolicy='per-photo',scopes={'lens':dict(cameraModel=source['metadata']['camera'],lensModel=source['metadata']['lens'],geometryPolicy='allow-native-crop',settings={'distortion':20})})
        lens_id = verify_scoped(lens_geometry)
        current = cli('get',source['id'])
        composed = recipe('apply',dict(recipeId=lens_id,sourceRef=source['id'],ifDocument=doc['openToken'],ifState=current['stateHash'],ifGeometryState=current['geometryStateHash'],geometry=dict(rotation=1,aspectRatio=1.5),preview=True))
        assert composed['status'] == 'succeeded'
        assert composed['scopedObserved']['lens']['distortion'] == 20
        assert abs(composed['observed']['geometry']['rotation']-1)<.001
        composed_crop = composed['observed']['geometry']['crop']
        assert abs(composed_crop['width']/composed_crop['height']-1.5)<.002
        # Explicit empty replacement removes the bands; omission above did not.
        clear = dict(preserve,settings={},scopes={'advancedColor':dict(mode='replace',bands=[])})
        clear_id = verify_scoped(clear)
        current = cli('get',source['id'])
        cleared = recipe('apply',dict(recipeId=clear_id,sourceRef=source['id'],ifDocument=doc['openToken'],ifState=current['stateHash']))
        assert cleared['status'] == 'succeeded' and cleared['scopedObserved']['advancedColor'] == []
        assert len(cli('variants','list')) == 1, 'Compound edits must not duplicate variants'
        assert sha(raw) == sha(fixture) == original
        log('passed',dict(group=group,rawSHA256=original,cliSHA256=sha(CLI),mcpSHA256=sha(MCP),session=str(base/'recipes')))
        apple('close current document')
    finally:
        if client: client.close()
        # Failed fixtures and unresolved operations remain available for inspection.


if __name__ == '__main__':
    main()
