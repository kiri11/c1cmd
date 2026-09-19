#!/usr/bin/env python3
"""Compound fault cases using the existing owned-fixture/restart watchdog harness.

Exercises real Apple Event timeouts in compound native, lens, tonal, geometry and
preview steps, plus layer color deletion through the shared native path.
mcp-death kills a compound MCP caller after an observed completed mutation step.
No faults are retried. Production binaries have no test hooks.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import time
import recovery_integration_test as harness


CASES = ('native','native-action','lens','layer-color','tonal','geometry','preview','mcp-death')


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive',type=Path)
    parser.add_argument('evidence',type=Path)
    parser.add_argument('--cases',nargs='+',choices=[*CASES,'all'],default=['all'])
    args = parser.parse_args(argv)
    if args.cases == ['all']: args.cases = list(CASES)
    elif 'all' in args.cases or len(set(args.cases)) != len(args.cases): parser.error('Select unique cases, or all alone')
    return args


class RecipeRun(harness.Run):
    def restart(self):
        super().restart()
        self.wait_native_document()

    def wait_native_document(self):
        # AppleScript can see the reopened document before Launch Services gives
        # short-lived CLI processes a stable application lifetime identity.
        stable = 0
        def ready():
            nonlocal stable
            result = subprocess.run([str(self.c1),'doc','info','--format','json'],capture_output=True,text=True,timeout=15)
            value = json.loads(result.stdout.strip() or result.stderr.strip())
            self.log('native-restart-readiness',code=result.returncode,response=value)
            if result.returncode:
                assert value['error']['code']=='app-not-running', value
                stable = 0
            else:
                assert Path(value['documentPath']).resolve()==self.session.resolve(),value
                stable += 1
            if stable == 3: return True
            time.sleep(.25)
            return False
        harness.wait_for(ready,60)

    def select_cases(self, cases):
        if not cases or len(set(cases)) != len(cases) or any(case not in CASES for case in cases):
            raise ValueError('Select unique scoped recipe recovery cases')
        return list(cases)

    def recipe_request(self, action, arguments, ok=True):
        path = self.work / ('recipe-' + str(time.time_ns()) + '.json')
        path.write_text(json.dumps(arguments))
        return self.cli('recipe', action, '--file', str(path), ok=ok)

    def seed_band(self, ref, layer=0):
        state = self.cli('get',ref,'--native-targets',json.dumps([dict(scope='adjustments',layer=layer)]))['nativeSnapshots'][0]
        self.cli('native','action',ref,'color.create','--scope','adjustments','--layer',str(layer),'--if-native-state',state['nativeStateHash'])
        return self.cli('get',ref,'--native-targets',json.dumps([dict(scope='advancedColor',layer=layer,element=1)]))['nativeSnapshots'][0]['values']

    def setup_recipe(self, settings, kind):
        source = self.cli('get', self.source)
        doc = self.cli('doc', 'info')
        capture = self.recipe_request('capture',dict(ref=self.source,ifDocument=doc['openToken'],ifState=source['stateHash']))
        payload = dict(version=1,referenceId=capture['referenceId'],settings=settings,
                       exposure=dict(mode='preserve'),whiteBalance=dict(mode='preserve'),cropPolicy='per-photo')
        clone, state = self.clone()
        if kind in ('native','native-action','lens','geometry','mcp-death'):
            payload['version'] = 2
            if kind == 'native':
                payload['scopes'] = dict(camera=dict(cameraModel=source['metadata']['camera'],settings={'film curve':'Linear Response'}))
            elif kind in ('lens','geometry'):
                payload['scopes'] = dict(lens=dict(cameraModel=source['metadata']['camera'],lensModel=source['metadata']['lens'],geometryPolicy='allow-native-crop' if kind == 'geometry' else 'preserve-crop',settings={'distortion':10} if kind == 'geometry' else {'light falloff':15}))
            else:
                band = self.seed_band(clone['workingRef'])
                payload['scopes'] = dict(advancedColor=dict(mode='replace',bands=[dict(band,**{'hue change':5})]))
        registered = self.recipe_request('register',dict(recipe=payload))
        verified = self.recipe_request('verify',dict(recipeId=registered['recipeId'],workingRef=clone['workingRef'],
                                       ifDocument=doc['openToken'],ifState=state['stateHash']))
        assert verified['status'] == 'succeeded'
        self.cli('variant','delete',clone['workingRef'])
        return registered['recipeId']

    def compound_fault(self, kind):
        if kind == "layer-color": return self.layer_color_fault()
        recipe_id = self.setup_recipe({'clarity amount':5,'rgb curve':[0,0,50,55,100,100],
            'film grain type':'silver rich','film grain impact':25,'film grain granularity':30,
            'vignetting method':'circular','vignetting amount':-.5} if kind in ('native','mcp-death') else {}, kind)
        clone, state = self.clone()
        if kind in ('native-action','mcp-death'):
            self.seed_band(clone['workingRef'])
            state = self.cli('get',clone['workingRef'])
        doc = self.cli('doc','info')
        args = dict(recipeId=recipe_id,sourceRef=clone['cloneVariantId'],ifDocument=doc['openToken'],ifState=state['stateHash'])
        if kind == 'lens': args['ifGeometryState'] = state['geometryStateHash']
        if kind in ('tonal','mcp-death'): args['exposure'] = dict(mode='absolute',value=.625)
        if kind == 'geometry': args.update(ifGeometryState=state['geometryStateHash'],geometry=dict(rotation=3,aspectRatio=1.5))
        if kind == 'preview': args['preview'] = True
        known = {r['operationId'] for r in self.records()}
        pid = self.pid()
        watchdog = None
        try:
            if kind == 'mcp-death':
                self.child = subprocess.Popen([str(self.mcp)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                def send(value):
                    self.child.stdin.write(json.dumps(value)+'\n'); self.child.stdin.flush()
                send(dict(jsonrpc='2.0',id=1,method='initialize',params=dict(protocolVersion='2024-11-05',capabilities={},clientInfo=dict(name='compound-recovery',version='1'))))
                import select
                assert select.select([self.child.stdout],[],[],15)[0]
                self.log('compound-mcp-initialize',response=json.loads(self.child.stdout.readline()))
                send(dict(jsonrpc='2.0',method='notifications/initialized'))
                send(dict(jsonrpc='2.0',id=2,method='tools/call',params=dict(name='edit_apply',arguments=args)))
                completed = harness.wait_for(lambda: next((r for r in self.records() if r['operationId'] not in known and r.get('compoundId') and r['status'] == 'succeeded'),None),90)
                self.child.kill()
                out, err = self.child.communicate(timeout=5)
                assert self.child.returncode == -signal.SIGKILL and not out.strip(), 'Compound already returned'
                compound = completed['compoundId']
                latest = self.recipe_request('status',dict(compoundId=compound),ok=False)
                assert latest['status'] == 'interrupted'
                children = latest['childOperations']
                assert any(r['operationId'] == completed['operationId'] and r['status'] == 'succeeded' for r in children)
                assert not any(r['operationType'] == 'preview' for r in children)
                self.log('compound-caller-killed-after-completed-step',report=latest,stderr=err)
                # If a subsequent child dispatched before process death it remains
                # uncertain and must use normal recovery, never guessed completion.
                pending = next((r for r in children if r['status'] in ('pending','outcome-unknown','partial-failure')),None)
                if pending:
                    recovery_ref = dict(clone,workingRef=latest['workingRef'])
                    self.recovery(pending['operationId'],recovery_ref,'compound-caller-death')
                else:
                    assert self.cli('get',self.source)['stateHash'] == self.original['stateHash']
                    assert harness.sha(self.raw) == self.raw_hash
                    self.log('case-passed',case='compound-caller-death-between-steps',compoundId=compound)
                return
            request = self.work / ('compound-' + kind + '.json'); request.write_text(json.dumps(args))
            self.child = subprocess.Popen([str(self.c1),'recipe','apply','--file',str(request),'--format','json'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            pending = harness.wait_for(lambda: next((r for r in self.records() if r['operationId'] not in known and r.get('compoundId') and r['status']=='pending' and (kind != 'geometry' or r['operationType']=='geometry_set')),None),90)
            watchdog = subprocess.Popen([sys.executable,'-c','import os,signal,sys,time; time.sleep(150); os.kill(int(sys.argv[1]),signal.SIGCONT)',str(pid)])
            os.kill(pid,signal.SIGSTOP); self.paused = pid
            self.log('compound-target-paused',kind=kind,pending=pending,limitation='External pause races Apple Event execution; no claim about which event was in flight.')
            out,err = self.child.communicate(timeout=145)
            result = json.loads(out or err)
            self.log('compound-timeout-result',kind=kind,result=result,code=self.child.returncode)
            assert self.child.returncode != 0 and result['status'] == 'outcome-unknown', result
            assert result['error']['code'] == 'timeout' and '-1712' in result['error']['message'],result
            assert result['error']['operationId'] == pending['operationId']
            assert result['compoundId'] == pending['compoundId']
            if kind == 'geometry': assert any(step['step']=='scope-lens' for step in result['completed'])
            assert all(step['step'] != 'observe' for step in result['completed'])
        finally:
            if self.paused:
                os.kill(pid,signal.SIGCONT); self.paused = None
            if watchdog:
                watchdog.terminate(); watchdog.wait(timeout=5)
            if self.child and self.child.poll() is None:
                self.child.kill(); self.child.wait()
        self.recovery(pending['operationId'],dict(clone,workingRef=result['workingRef']),'compound-' + kind + '-timeout')
        final = self.recipe_request('status',dict(compoundId=result['compoundId']),ok=False)
        assert final['status'] == 'outcome-unknown', 'Child reconciliation must not promote parent completion'

    def layer_color_fault(self):
        # Exercise the shared native readback/reconciliation context on a layer,
        # while recipes themselves remain image-only.
        clone, _ = self.clone()
        state = self.cli('get',clone['workingRef'],'--native-targets','[{"scope":"adjustments"}]')['nativeSnapshots'][0]
        created = self.cli('native','action',clone['workingRef'],'layer.create','--scope','adjustments','--if-native-state',state['nativeStateHash'],'--json',json.dumps(dict(name='Layer color recovery',kind='adjustment')))
        layer = len(created['after']['layers'])
        self.seed_band(clone['workingRef'],layer)
        self.seed_band(clone['workingRef'],layer)
        state = self.cli('get',clone['workingRef'],'--native-targets',json.dumps([dict(scope='advancedColor',layer=layer,element=1)]))['nativeSnapshots'][0]
        assert state['advancedColorCount'] == 2
        known = {r['operationId'] for r in self.records()}
        pid = self.pid()
        watchdog = None
        try:
            command = [str(self.c1),'native','action',clone['workingRef'],'color.delete','--scope','advancedColor','--layer',str(layer),'--element','1','--if-native-state',state['nativeStateHash'],'--format','json']
            self.child = subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            pending = harness.wait_for(lambda: next((r for r in self.records() if r['operationId'] not in known and r['status']=='pending'),None),90)
            watchdog = subprocess.Popen([sys.executable,'-c','import os,signal,sys,time; time.sleep(150); os.kill(int(sys.argv[1]),signal.SIGCONT)',str(pid)])
            os.kill(pid,signal.SIGSTOP); self.paused = pid
            self.log('layer-color-target-paused',pending=pending,limitation='External pause races Apple Event execution.')
            out,err = self.child.communicate(timeout=145)
            result = json.loads(out or err)
            self.log('layer-color-timeout-result',result=result,code=self.child.returncode)
            assert self.child.returncode != 0 and result['error']['code']=='timeout' and '-1712' in result['error']['message'],result
            assert result['error']['operationId']==pending['operationId']
        finally:
            if self.paused: os.kill(pid,signal.SIGCONT); self.paused=None
            if watchdog: watchdog.terminate(); watchdog.wait(timeout=5)
            if self.child and self.child.poll() is None: self.child.kill(); self.child.wait()
        self.recovery(pending['operationId'],clone,'layer-color-delete-timeout')
        observed = self.cli('operation','status',pending['operationId'])
        assert observed['beforeNative']['target']['layer']==layer
        assert observed['afterNative']['target']==dict(scope='adjustments',layer=layer,element=0)
        assert observed['afterNative']['advancedColorCount'] in (1,2), observed
        self.log('layer-color-context-passed',operationId=pending['operationId'],layer=layer)

    def run_cases(self, cases):
        for case in cases:
            assert case in CASES
            self.compound_fault(case)


def main():
    args = parse_args()
    assert all(case in CASES for case in args.cases)
    run = RecipeRun(args.archive,args.evidence)
    shutil.copy2(__file__, run.evidence / "compound-harness.py")
    run.log("compound-harness", sha256=harness.sha(Path(__file__)))
    try: run.run(args.cases)
    except BaseException as error:
        run.log('failed',error=repr(error)); raise
    finally: run.finish()


if __name__ == '__main__': main()
