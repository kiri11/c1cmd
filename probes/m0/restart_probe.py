"""Normal saved application restart; only fixture documents are mutated.
Retains the original Catalog as an open document. Never uses silently quit.
"""
import json
from pathlib import Path
import subprocess
import time
root=Path(__file__).resolve().parents[2]
def ae(body):
    p=subprocess.run(['osascript','-s','s','-e','tell application "/Applications/Capture One.app"\n'+body+'\nend tell'],capture_output=True,text=True,timeout=45)
    return {'code':p.returncode,'out':p.stdout,'err':p.stderr}
def pid():
    return subprocess.run(['pgrep','-x','Capture One'],capture_output=True,text=True).stdout.strip()
snapshot='''set a to document "c1-m0-1685-A.cosessiondb"
set b to document "c1-m0-1685-B.cosessiondb"
return {documents:name of every document, aId:id of a, aVariants:id of every variant of a, aStates:{exposure, contrast, temperature, tint} of adjustments of every variant of a, bId:id of b, bCount:count of variants of b, currentId:id of current document}'''
report={'before':ae(snapshot),'beforePid':pid()}
assert report['before']['code']==0
report['quit']=ae('quit')
assert report['quit']['code']==0,report
deadline=time.monotonic()+30
while pid() and time.monotonic()<deadline:time.sleep(.1)
assert not pid(),'Normal quit has not completed; do not force termination'
report['confirmedExited']=True
report['launch']=ae('launch')
for path in ['/Users/kiri11/Pictures/Capture One Catalog.cocatalog','/private/tmp/c1-m0-1685-A/c1-m0-1685-A.cosessiondb','/private/tmp/c1-m0-1685-B/c1-m0-1685-B.cosessiondb']:
    report.setdefault('opens',[]).append(ae('open POSIX file "'+path+'"'))
report['after']=ae(snapshot)
report['afterPid']=pid()
(root/'docs/m0/16.8.5.30/restart.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
