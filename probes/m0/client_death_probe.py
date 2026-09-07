"""Kill only a disposable probe client after dispatch, before its final reply.
The target application remains alive. Never retries the export.
"""
import json
from pathlib import Path
import subprocess
import time
root = Path(__file__).resolve().parents[2]
script = root/'probes/m0/12_pending_export.applescript'
marker = Path('/private/tmp/c1-m0-pending-job-foreground.txt')
assert not marker.exists(), 'Existing run; reconcile instead of repeating'
output = Path('/private/tmp/c1-m0-1685-A/Output/job-client-death-foreground/variant-2.jpg')
assert not output.exists(), 'Output must be new'
def call(action):
    r = subprocess.run(['osascript','-s','s',str(script),action],capture_output=True,text=True,timeout=15)
    return {'code':r.returncode,'out':r.stdout,'err':r.stderr}
report = {'initial':call('inspect')}
client = subprocess.Popen(['osascript','-s','s',str(script),'stage'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
try:
    deadline = time.monotonic()+15
    while not marker.exists() and time.monotonic()<deadline:
        if client.poll() is not None: raise RuntimeError(client.communicate())
        time.sleep(0.05)
    assert marker.exists(), 'Dispatch not established'
    report['jobId'] = marker.read_text()
    client.kill()
    stdout,stderr = client.communicate(timeout=5)
    report['client'] = {'code':client.returncode,'stdout':stdout,'stderr':stderr}
    report['afterClientDeath'] = call('inspect')
finally:
    if client.poll() is None:
        client.kill();client.wait()
    report['resume'] = call('resume')
deadline=time.monotonic()+15
report['polls']=[]
while time.monotonic()<deadline:
    state=call('inspect');report['polls'].append(state)
    if output.exists() and 'cloneQueued:false' in state['out']: break
    time.sleep(0.1)
report['outputExists']=output.exists()
report['outputBytes']=output.stat().st_size if output.exists() else None
(root/'docs/m0/16.8.5.30/client_death_foreground.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
