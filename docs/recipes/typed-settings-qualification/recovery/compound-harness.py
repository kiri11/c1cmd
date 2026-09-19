#!/usr/bin/env python3
"""Compound fault cases using the existing owned-fixture/restart watchdog harness.

Maps native, tonal, geometry, preview to real Apple Event timeouts inside edit_apply;
mcp-death kills a compound MCP caller after an observed completed settings step.
No faults are retried. Production binaries have no test hooks.
"""
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import time
import recovery_integration_test as harness


class RecipeRun(harness.Run):
    def recipe_request(self, action, arguments, ok=True):
        path = self.work / ('recipe-' + str(time.time_ns()) + '.json')
        path.write_text(json.dumps(arguments))
        return self.cli('recipe', action, '--file', str(path), ok=ok)

    def setup_recipe(self, settings):
        source = self.cli('get', self.source)
        doc = self.cli('doc', 'info')
        capture = self.recipe_request('capture',dict(ref=self.source,ifDocument=doc['openToken'],ifState=source['stateHash']))
        payload = dict(version=1,referenceId=capture['referenceId'],settings=settings,
                       exposure=dict(mode='preserve'),whiteBalance=dict(mode='preserve'),cropPolicy='per-photo')
        registered = self.recipe_request('register',dict(recipe=payload))
        clone, state = self.clone()
        verified = self.recipe_request('verify',dict(recipeId=registered['recipeId'],workingRef=clone['workingRef'],
                                       ifDocument=doc['openToken'],ifState=state['stateHash']))
        assert verified['status'] == 'succeeded'
        self.cli('variant','delete',clone['workingRef'])
        return registered['recipeId']

    def compound_fault(self, kind):
        recipe_id = self.setup_recipe({'clarity amount':5,'rgb curve':[0,0,50,55,100,100],
            'film grain type':'silver rich','film grain impact':25,'film grain granularity':30,
            'vignetting method':'circular','vignetting amount':-.5} if kind in ('native','mcp-death') else {})
        clone, state = self.clone()
        doc = self.cli('doc','info')
        args = dict(recipeId=recipe_id,sourceRef=clone['cloneVariantId'],ifDocument=doc['openToken'],ifState=state['stateHash'])
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
            watchdog = subprocess.Popen([sys.executable,'-c','import os,signal,sys,time; time.sleep(150); os.kill(int(sys.argv[1]),signal.SIGCONT)',str(pid)])
            self.child = subprocess.Popen([str(self.c1),'recipe','apply','--file',str(request),'--format','json'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            pending = harness.wait_for(lambda: next((r for r in self.records() if r['operationId'] not in known and r.get('compoundId') and r['status']=='pending'),None),90)
            os.kill(pid,signal.SIGSTOP); self.paused = pid
            self.log('compound-target-paused',kind=kind,pending=pending,limitation='External pause races Apple Event execution; no claim about which event was in flight.')
            out,err = self.child.communicate(timeout=145)
            result = json.loads(out or err)
            self.log('compound-timeout-result',kind=kind,result=result,code=self.child.returncode)
            assert self.child.returncode != 0 and result['status'] == 'outcome-unknown', result
            assert result['error']['code'] == 'timeout' and '-1712' in result['error']['message'],result
            assert result['error']['operationId'] == pending['operationId']
            assert result['compoundId'] == pending['compoundId']
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

    def run_cases(self, cases):
        for case in cases:
            assert case in ('native','tonal','geometry','preview','mcp-death')
            self.compound_fault(case)


def main():
    args = harness.parse_args()
    assert all(case in ('native','tonal','geometry','preview','mcp-death') for case in args.cases)
    run = RecipeRun(args.archive,args.evidence)
    shutil.copy2(__file__, run.evidence / "compound-harness.py")
    run.log("compound-harness", sha256=harness.sha(Path(__file__)))
    try: run.run(args.cases)
    except BaseException as error:
        run.log('failed',error=repr(error)); raise
    finally: run.finish()


if __name__ == '__main__': main()
