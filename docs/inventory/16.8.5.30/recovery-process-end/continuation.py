"""Complete remaining checks using explicit process-end restarts after native quit stalls.
All uncertain writes are reconciled, never repeated. Retains separate evidence.
"""
from pathlib import Path
import sys, json, os, signal, subprocess, shutil, types
sys.path.insert(0, '/Users/kiri11/projects/c1cmd/Tests')
from recovery_integration_test import Run, ROOT, ae, wait_for, sha

prior = Path('/private/tmp/c1-inventory-qualification-20260916-final/recovery')
events = [json.loads(line) for line in (prior/'events.jsonl').read_text().splitlines()]
continued = [json.loads(line) for line in (prior.parent/'recovery-continuation/events.jsonl').read_text().splitlines()]
environment = next(e for e in events if e['event']=='environment')
r=Run.__new__(Run)
r.evidence=prior.parent/'recovery-process-end'
r.evidence.mkdir(exist_ok=False)
r.events=r.evidence/'events.jsonl'
shutil.copy2(__file__,r.evidence/'continuation.py')
shutil.copy2(ROOT/'Tests/recovery_integration_test.py',r.evidence/'harness.py')
r.work=Path('/private/tmp/c1-recovery-1ujzomvx')
r.session=r.work/'recovery'
r.db=r.session/'recovery.cosessiondb'
r.journal=r.session/'.c1/journal.jsonl'
r.raw=r.session/'Capture/fixture.CR3'
r.raw_hash=environment['sourceRAW_SHA256']
r.child=None
r.paused=None
r.owns_session=False
r.hidden_bundle=None
r.source='1'
r.original=next(e['response'] for e in events if e.get('args')==['get','1'])
package=r.work/'archive/c1-v0.1.0-macos-arm64'
r.c1=package/'bin/c1'
r.mcp=package/'bin/c1-mcp'
operation='e2a95b5d-8cac-4951-81fd-af88412dee53'
records=[json.loads(x) for x in r.journal.read_text().splitlines()]
entry=[x for x in records if x['operationId']==operation][-1]
clone={'workingRef':entry['workingRef']}
oldpid=int(entry['appInstance'].split(':')[0])
before=sorted((v['id'],v['parentImagePath']) for v in [e['response'] for e in continued if e.get('args')==['variants','list']][-1])

def end_and_open(self, old):
    assert ae('return count of documents')==0
    assert self.pid()==old
    os.kill(old, signal.SIGTERM)
    wait_for(lambda:subprocess.run(['kill','-0',str(old)],capture_output=True).returncode != 0,30)
    self.log('manual-process-end',oldPid=old,signal='SIGTERM',openDocumentsBefore=0)
    subprocess.run(['open','-a','/Applications/Capture One.app',str(self.db)],check=True)
    def ready():
        try:return Path(ae('return id of first document',timeout=5)).resolve()==self.session.resolve()
        except(RuntimeError,subprocess.TimeoutExpired):return False
    wait_for(ready,60)
    self.owns_session=True
    assert self.pid()!=old
    self.log('restart',oldPid=old,newPid=self.pid(),method='SIGTERM-after-owned-document-close')

def explicit_restart(self):
    assert Path(ae('return id of first document')).resolve()==self.session.resolve()
    old=self.pid()
    ae('close first document',timeout=60)
    end_and_open(self,old)

try:
    assert sha(r.c1)==environment['cliSHA256'] and sha(r.mcp)==environment['mcpSHA256']
    assert sha(next(package.rglob('Handlers.applescript')))==environment['handlersSHA256']
    bundle=ROOT/'.build/release/c1_CaptureOneCore.bundle'
    hidden=bundle.with_name('c1_CaptureOneCore.bundle.recovery-hidden')
    assert not hidden.exists()
    bundle.rename(hidden)
    r.hidden_bundle=(hidden,bundle)
    r.log('continuation-environment',priorEvidence=str(prior.parent/'recovery-continuation'),
          operationId=operation,cliSHA256=sha(r.c1),mcpSHA256=sha(r.mcp),buildResourceFallbackHidden=True)
    end_and_open(r,oldpid)
    blocked=r.cli('variant','clone',r.source,ok=False)
    assert blocked['error']['code']=='outcome-unknown' and blocked['error']['operationId']==operation
    reconciled=r.cli('operation','status',operation)
    assert reconciled['status']=='reconciled'
    stale=r.cli('get',clone['workingRef'],ok=False)
    assert stale['error']['code']=='document-changed'
    assert r.identities()==before
    original=r.cli('get',r.source)
    assert original['stateHash']==r.original['stateHash'] and original['geometry']==r.original['geometry']
    assert sha(r.raw)==r.raw_hash
    fresh,current=r.clone()
    r.cli('set',fresh['workingRef'],'--if-state',current['stateHash'],'exposure=0.125')
    r.cli('variant','delete',fresh['workingRef'])
    assert r.identities()==before
    r.log('case-passed',case='preview-timeout-recovery-after-manual-process-end',operationId=operation,observations=reconciled)
    r.restart=types.MethodType(explicit_restart,r)
    r.mcp_death()
    assert sha('/private/tmp/c1-geometry-live-j99twntf/geometry/Capture/2U6A7257.CR3')==r.raw_hash
    r.log('continuation-passed',cases=2,sourceRAW_SHA256=r.raw_hash)
except BaseException as error:
    r.log('failed',error=repr(error))
    raise
finally:
    r.finish()
