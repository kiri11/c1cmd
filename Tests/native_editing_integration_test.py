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
        # Independent direct-property oracle bypasses nativeRead/nativeWriteField.
        balance_fields = [f['name'] for f in json.loads(
            (ROOT / 'Sources/CaptureOneCore/Resources/NativeEditing.json').read_text())['adjustments']
            if f['name'].startswith('color balance ')]
        def balance_oracle(layer):
            context = 'adjustments of v' if layer == 0 else f'adjustments of layer {layer} of v'
            body = f'''if (count of documents) is not 1 then error "Document changed"
set d to current document
if (id of d as text) is not {json.dumps(doc['documentId'])} then error "Document changed"
set v to variant id {json.dumps(source['id'])} of d
return {{{', '.join(f'({field} of {context})' for field in balance_fields)}}}'''
            values = dict(zip(balance_fields, json.loads(apple(body).replace('{', '[').replace('}', ']'))))
            log('balance-oracle', dict(layer=layer, values=values))
            return values
        def balance_equal(field, actual, expected):
            distance = abs(actual - expected)
            if field.endswith(' hue'):
                distance = min(distance, abs(360 - distance))
            return distance <= .0001
        for balance_layer in [0, index]:
            baseline = balance_oracle(balance_layer)
            for band in ['master', 'shadow', 'midtone', 'highlight']:
                hue, sat = [f'color balance {band} {field}' for field in ['hue', 'saturation']]
                for values in [{hue:237, sat:.2}, {sat:.3}, {hue:123},
                               {hue:baseline[hue], sat:baseline[sat]}]:
                    before_balance = balance_oracle(balance_layer)
                    patch(values, layer=balance_layer)
                    observed = balance_oracle(balance_layer)
                    expected_balance = dict(before_balance, **values)
                    for field, expected_value in expected_balance.items():
                        assert balance_equal(field, observed[field], expected_value), (field, observed, expected_balance)
            for field, value in balance_oracle(balance_layer).items():
                assert balance_equal(field, value, baseline[field])
        patch({'opacity':63,'name':'Native tested'},'layer',index)
        patch({'exposure':.35,'clarity amount':7},layer=index)
        luma = get('luma',index)
        patch({'range low':10,'range high':240},'luma',index)
        action('luma.clear',scope='layer',layer=index)
        for mask in ['mask.clear','mask.fill','mask.invert','mask.rasterize']:
            action(mask,scope='layer',layer=index)
        action('mask.feather',{'amount':10},scope='layer',layer=index)
        action('mask.refine',{'amount':10},scope='layer',layer=index)
        def color_oracle(scope, layer):
            # Read property records in one bulk event, never evaluated element objects.
            fields = [f['name'] for f in json.loads(
                (ROOT / 'Sources/CaptureOneCore/Resources/NativeEditing.json').read_text())[scope]]
            kind = 'basic' if scope == 'basicColor' else 'advanced'
            context = 'adjustments of v' if layer == 0 else f'adjustments of layer {layer} of v'
            body = f'''if (count of documents) is not 1 then error "Document changed"
set d to current document
if (id of d as text) is not {json.dumps(doc['documentId'])} then error "Document changed"
set v to variant id {json.dumps(source['id'])} of d
set colorPropertyRows to properties of every {kind} color correction of color editor settings of {context}
set rows to {{}}
repeat with r in colorPropertyRows
    set end of rows to {{{', '.join(f'({field} of r)' for field in fields)}}}
end repeat
return rows'''
            rows = json.loads(apple(body).replace('{', '[').replace('}', ']'))
            value = [dict(zip(fields, row)) for row in rows]
            log('color-oracle', dict(scope=scope, layer=layer, values=value))
            return value

        for color_layer in [0, index]:
            for scope in ['basicColor', 'advancedColor']:
                if scope == 'advancedColor':
                    # Three elements make an index alias observable through sibling checks.
                    for _ in range(3):
                        action('color.create', layer=color_layer)
                before = color_oracle(scope, color_layer)
                if scope == 'basicColor':
                    assert [r['name'] for r in before] == [
                        'red', 'orange', 'yellow', 'green', 'cyan', 'blue', 'purple', 'pink', 'all']
                else:
                    assert len(before) == 3
                for element, expected in enumerate(before, 1):
                    assert get(scope, color_layer, element)['values'] == expected
                # Address an interior band, verify every property of every sibling.
                element = 2
                changed = [dict(row) for row in before]
                changed[element - 1]['hue change'] = 5.0
                patch({'hue change':5}, scope, color_layer, element)
                assert color_oracle(scope, color_layer) == changed
                for n, expected in enumerate(changed, 1):
                    assert get(scope, color_layer, n)['values'] == expected
                patch({'hue change':before[element - 1]['hue change']}, scope, color_layer, element)
                assert color_oracle(scope, color_layer) == before
                if scope == 'advancedColor':
                    # Distinguish siblings before deleting the middle element.
                    patch({'hue change':3}, scope, color_layer, 1)
                    patch({'hue change':7}, scope, color_layer, 3)
                    marked = color_oracle(scope, color_layer)
                    action('color.delete', scope=scope, layer=color_layer, element=2)
                    assert color_oracle(scope, color_layer) == [marked[0], marked[2]]
                    action('color.delete', scope=scope, layer=color_layer, element=2)
                    action('color.delete', scope=scope, layer=color_layer, element=1)
                    assert color_oracle(scope, color_layer) == []
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
