"""Continue the retained inventory qualification after a native quit timed out.
No faulted mutation is retried. The interrupted make qualify remains a failed run.
"""
from pathlib import Path
import sys, json, os, signal, subprocess, shutil
sys.path.insert(0, '/Users/kiri11/projects/c1cmd/Tests')
from recovery_integration_test import Run, ROOT, ae, wait_for, sha

prior = Path('/private/tmp/c1-inventory-qualification-20260916-final/recovery')
events = [json.loads(line) for line in (prior/'events.jsonl').read_text().splitlines()]
environment = next(e for e in events if e['event']=='environment')
r = Run.__new__(Run)
r.evidence = prior.parent/'recovery-continuation'
r.evidence.mkdir(exist_ok=False)
r.events = r.evidence/'events.jsonl'
shutil.copy2(__file__, r.evidence/'continuation.py')
shutil.copy2(ROOT/'Tests/recovery_integration_test.py',r.evidence/'harness.py')
r.work = Path('/private/tmp/c1-recovery-1ujzomvx')
r.session = r.work/'recovery'
r.db = r.session/'recovery.cosessiondb'
r.journal = r.session/'.c1/journal.jsonl'
r.raw = r.session/'Capture/fixture.CR3'
r.raw_hash = environment['sourceRAW_SHA256']
r.child = None
r.paused = None
r.owns_session = False
r.hidden_bundle = None
r.source = '1'
r.original = next(e['response'] for e in events if e.get('args')==['get','1'])
package = r.work/'archive/c1-v0.1.0-macos-arm64'
r.c1 = package/'bin/c1'
r.mcp = package/'bin/c1-mcp'
pending = [e['pending'] for e in events if e['event']=='target-paused-after-pending'][-1]
operation = pending['operationId']
clone = {'workingRef':pending['workingRef']}
before = [('1',r.original['parentImagePath']),('12',r.original['parentImagePath']),('18',r.original['parentImagePath'])]

try:
    assert sha(r.c1)==environment['cliSHA256'] and sha(r.mcp)==environment['mcpSHA256']
    assert sha(next(package.rglob('Handlers.applescript')))==environment['handlersSHA256']
    bundle=ROOT/'.build/release/c1_CaptureOneCore.bundle'
    hidden=bundle.with_name('c1_CaptureOneCore.bundle.recovery-hidden')
    assert not hidden.exists()
    bundle.rename(hidden)
    r.hidden_bundle=(hidden,bundle)
    r.log('continuation-environment', priorEvidence=str(prior), operationId=operation,
          cliSHA256=sha(r.c1), mcpSHA256=sha(r.mcp), buildResourceFallbackHidden=True)
    assert ae('return count of documents')==0
    assert r.pid()==85924
    os.kill(85924, signal.SIGTERM)
    wait_for(lambda: subprocess.run(['kill','-0','85924'],capture_output=True).returncode != 0, 30)
    r.log('manual-process-end', oldPid=85924, signal='SIGTERM', openDocumentsBefore=0)
    subprocess.run(['open','-a','/Applications/Capture One.app',str(r.db)],check=True)
    def ready():
        try: return Path(ae('return id of first document',timeout=5)).resolve()==r.session.resolve()
        except (RuntimeError,subprocess.TimeoutExpired): return False
    wait_for(ready,60)
    r.owns_session=True
    assert r.pid()!=85924
    blocked=r.cli('variant','clone',r.source,ok=False)
    assert blocked['error']['code']=='outcome-unknown' and blocked['error']['operationId']==operation
    reconciled=r.cli('operation','status',operation)
    assert reconciled['status']=='reconciled'
    assert reconciled.get('beforeGeometry') and reconciled.get('intendedGeometry') and reconciled.get('afterGeometry')
    stale=r.cli('get',clone['workingRef'],ok=False)
    assert stale['error']['code']=='document-changed'
    assert r.identities()==before
    original=r.cli('get',r.source)
    assert original['stateHash']==r.original['stateHash'] and original['geometry']==r.original['geometry']
    assert sha(r.raw)==r.raw_hash
    fresh,current=r.clone()
    r.cli('set',fresh['workingRef'],'--if-state',current['stateHash'],'exposure=0.125')
    geometry=r.cli('get',fresh['workingRef'])['geometryStateHash']
    r.cli('geometry','set',fresh['workingRef'],'--if-geometry-state',geometry,'--rotation','2','--aspect-ratio','1.5')
    r.cli('variant','delete',fresh['workingRef'])
    assert r.identities()==before
    r.log('case-passed',case='geometry-timeout-recovery-after-manual-process-end',operationId=operation,observations=reconciled)
    r.preview_timeout()
    r.mcp_death()
    assert sha('/private/tmp/c1-geometry-live-j99twntf/geometry/Capture/2U6A7257.CR3')==r.raw_hash
    r.log('continuation-passed', cases=3, sourceRAW_SHA256=r.raw_hash)
except BaseException as error:
    r.log('failed',error=repr(error))
    raise
finally:
    r.finish()
