"""Application-wide flock behavior across document labels and process death.
This tests the lock primitive, not a nonexistent c1 CLI/journal integration.
"""
import fcntl
import json
from pathlib import Path
import subprocess
import sys
import time
lockpath='/private/tmp/c1-m0-application-instance.lock'
root=Path(__file__).resolve().parents[2]
if len(sys.argv)>1:
    start=time.monotonic()
    with open(lockpath,'a+') as f:
        try:
            fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
            print(json.dumps({'document':sys.argv[1],'acquired':True,'seconds':time.monotonic()-start}),flush=True)
            if sys.argv[1]=='holder':time.sleep(30)
        except BlockingIOError:
            print(json.dumps({'document':sys.argv[1],'acquired':False,'seconds':time.monotonic()-start}),flush=True)
    sys.exit(0)
def worker(label):
    return json.loads(subprocess.check_output([sys.executable,__file__,label],text=True))
with open(lockpath,'a+') as f:
    fcntl.flock(f,fcntl.LOCK_EX)
    same=worker('A');different=worker('B')
released=worker('B')
holder=subprocess.Popen([sys.executable,__file__,'holder'],stdout=subprocess.PIPE,text=True)
assert json.loads(holder.stdout.readline())['acquired']
holder.kill();holder.wait()
afterDeath=worker('B')
report={'sameDocumentBlocked':not same['acquired'],'differentDocumentBlocked':not different['acquired'],
        'acquiredAfterRelease':released['acquired'],'acquiredAfterHolderDeath':afterDeath['acquired'],
        'workers':[same,different,released,afterDeath]}
assert all(report[k] for k in ['sameDocumentBlocked','differentDocumentBlocked','acquiredAfterRelease','acquiredAfterHolderDeath'])
(root/'docs/m0/16.8.5.30/lock.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
