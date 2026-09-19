#!/usr/bin/env python3
"""Native editing in an owned disposable Session; never retry uncertain writes."""
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
    assert raw.is_file()
    original = sha(raw)
    assert apple('return count of documents') == '0', 'Close documents before native qualification'
    base = Path(tempfile.mkdtemp(prefix='c1-native-', dir=str(ROOT / '.build')))
    evidence = Path(os.environ.get('C1_NATIVE_EVIDENCE', base / 'evidence'))
    evidence.mkdir(parents=True, exist_ok=True)
    events = []
    def log(name, value):
        events.append(dict(event=name, value=value))
        (evidence/'results.json').write_text(json.dumps(events, indent=2)+'\n')
        print(name, flush=True)
    def cli(*args):
        r = subprocess.run([str(CLI), *map(str,args), '--format','json'],capture_output=True,text=True,timeout=180)
        assert r.returncode == 0, r.stderr
        return json.loads(r.stdout)
    schema = cli("schema")
    client = None
    try:
        apple(f'make new document with properties {{name:"native", kind:session, path:{json.dumps(str(base))}}}')
        fixture = base / 'native/Capture' / raw.name
        shutil.copy2(raw, fixture)
        apple('set current collection of current document to collection "Capture" of current document')
        for _ in range(40):
            variants = cli('variants','list')
            if variants: break
            time.sleep(.5)
        assert len(variants) == 1
        source = cli('get',variants[0]['id']); doc = cli('doc','info')
        ref = cli('variant','edit',source['id'],'--if-state',source['stateHash'],'--if-document',doc['openToken'])['workingRef']
        sibling = cli('variant','clone',source['id'])
        sibling_before = cli('get',sibling['workingRef'],'--native-targets','[{"scope":"adjustments"}]')['nativeSnapshots'][0]
        client = Client(MCP, timeout=180)
        def tool(name, args):
            r = client.tool(name,args)
            value = json.loads(r['content'][0]['text'])
            log(name, value)
            assert not r.get('isError'), value
            validate_response(value, schema['responses'][name])
            return value
        def get(scope='adjustments',layer=0,element=0):
            return tool('get',dict(ref=ref,nativeTargets=[dict(scope=scope,layer=layer,element=element)]))['nativeSnapshots'][0]
        def patch(values,scope='adjustments',layer=0,element=0):
            state = get(scope,layer,element)
            result = tool('native_set',dict(workingRef=ref,target=state['target'],ifNativeState=state['nativeStateHash'],patch=values))
            return result
        def action(name,args=None,scope='adjustments',layer=0,element=0):
            state = get(scope,layer,element)
            return tool('native_action',dict(workingRef=ref,target=state['target'],ifNativeState=state['nativeStateHash'],action=name,arguments=args or {}))
        targets = [dict(scope=scope) for scope in ['adjustments', 'lens', 'variant']]
        singles = [get(scope=t['scope']) for t in targets]
        bundle = tool('get', dict(ref=ref, nativeTargets=targets + [targets[0]]))
        assert bundle['nativeSnapshots'] == singles + [singles[0]]
        assert bundle['id'] == source['id'] and bundle['openToken'] == doc['openToken']
        assert cli('get', ref, '--native-targets', json.dumps(targets))['nativeSnapshots'] == singles
        tool('native_set', dict(workingRef=ref, target=bundle['nativeSnapshots'][0]['target'],
             ifNativeState=bundle['nativeSnapshots'][0]['nativeStateHash'], patch={'clarity amount':3}))
        patch({'clarity amount':singles[0]['values']['clarity amount']})
        initial = get()
        dry = tool('native_set',dict(workingRef=ref,target=initial['target'],ifNativeState=initial['nativeStateHash'],patch={'clarity amount':5},dryRun=True))
        assert dry['after'] == initial

        assert len(initial['values']) > 70, initial
        if os.environ.get('C1_NATIVE_TEST_GROUP', 'all') == 'all':
            for curve in ['rgb curve','luma curve','red curve','green curve','blue curve']:
                patch({curve:[0,0,50,55,100,100]})
                patch({curve:initial['values'][curve]})
            patch({'highlight adjustment':20,'shadow recovery':15,'white recovery':-5,'black recovery':5})
            patch({'clarity amount':12,'clarity structure':8,'sharpening amount':170,'sharpening radius':.9,'noise reduction luminance':30,'noise reduction color':40})
            patch({'level shadow rgb':3,'level highlight rgb':250,'level midtone rgb':.1})
            patch({'black and white':True,'black and white red sensitivity':10})
            patch({'black and white':False})
            patch({'color balance shadow saturation':.05})
            patch({'clarity method':initial['values']['clarity method']})
            lens = get('lens')
            patch({'chromatic aberration':True},'lens')
            patch({'chromatic aberration':lens['values']['chromatic aberration']},'lens')
        action('layer.create',{'name':'Native qualification','kind':'filled'})
        layers = get()['layers']; index = len(layers)
        layer_targets = [dict(scope=scope, layer=index) for scope in ['adjustments', 'layer', 'luma']]
        layer_singles = [get(scope=t['scope'], layer=index) for t in layer_targets]
        assert tool('get', dict(ref=ref, nativeTargets=layer_targets))['nativeSnapshots'] == layer_singles
        patch({'opacity':63,'name':'Native tested'},'layer',index)
        patch({'exposure':.35,'clarity amount':7},layer=index)
        luma = get('luma',index)
        patch({'range low':10,'range high':240},'luma',index)
        action('luma.clear',scope='layer',layer=index)
        for mask in ['mask.clear','mask.fill','mask.invert','mask.rasterize']:
            action(mask,scope='layer',layer=index)
        action('mask.feather',{'amount':10},scope='layer',layer=index)
        action('mask.refine',{'amount':10},scope='layer',layer=index)
        basic = get('basicColor',0,1)
        patch({'hue change':5},'basicColor',0,1)
        patch({'hue change':basic['values']['hue change']},'basicColor',0,1)
        action('color.create')
        n = get()['advancedColorCount']
        advanced = get('advancedColor',0,n)
        patch({'hue change':5},'advancedColor',0,n)
        action('color.delete',scope='advancedColor',element=n)
        action('layer.create',{'name':'Mask copy target','kind':'adjustment'})
        copy_index = len(get()['layers'])
        action('mask.copy',{'sourceLayer':index},scope='layer',layer=copy_index)
        action('layer.delete',scope='layer',layer=copy_index)
        # AI can return no new layers when there is no matching person; retain observations.
        action('mask.people',{'areas':['body skin','face skin'],'separateLayers':False})
        # Native deletion is limited to the addressed layer, never the variant.
        action('layer.delete',scope='layer',layer=index)
        stale = client.tool('native_set',dict(workingRef=ref,target=initial['target'],ifNativeState=initial['nativeStateHash'],patch={'clarity amount':5}))
        assert stale.get('isError') and json.loads(stale['content'][0]['text'])['error']['code'] == 'state-changed'
        sibling_after = cli('get',sibling['workingRef'],'--native-targets','[{"scope":"adjustments"}]')['nativeSnapshots'][0]
        assert sibling_before == sibling_after, 'Native writes changed the untouched sibling'
        assert len(cli('variants','list')) == 2
        cli('variant','delete',sibling['workingRef'])
        assert len(cli('variants','list')) == 1
        assert sha(raw) == sha(fixture) == original
        preview = cli('preview',ref)
        log('preview',preview)
        log('passed',dict(group=os.environ.get('C1_NATIVE_TEST_GROUP','all'),rawSHA256=original,session=str(base/'native'),cliSHA256=sha(CLI),mcpSHA256=sha(MCP)))
        apple('close current document')
    finally:
        if client: client.close()

if __name__ == '__main__': main()
