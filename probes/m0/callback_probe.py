"""Journal-before-install and compare-before-restore callback feasibility probe.
Requires an initially unset callback; uses only fixture exports. Does not claim
an atomic compare-and-set against simultaneous photographer changes.
"""
import json
from pathlib import Path
import plistlib
import subprocess
import time
root=Path(__file__).resolve().parents[2]
evidence=root/'docs/m0/16.8.5.30'
folder=Path('/private/tmp/c1-m0-callbacks');folder.mkdir(exist_ok=True)
installed='/tmp/c1-m0-callback.scpt'
alternate='/tmp/c1-m0-callback-alternate.scpt'
def ae(body):
    p=subprocess.run(['osascript','-s','s','-e','tell application "/Applications/Capture One.app"\n'+body+'\nend tell'],capture_output=True,text=True,timeout=15)
    if p.returncode:raise RuntimeError(p.stderr)
    return p.stdout.strip()
initial=ae('return processing done script')
assert initial=='missing value', 'Preserve existing user callback'
assert ae('return id of current document')=='"/private/tmp/c1-m0-1685-A"'
for path in [installed,alternate]:
    subprocess.run(['osacompile','-o',path,str(root/'probes/m0/14_callback.applescript')],check=True)
journal={'initial':initial,'installed':installed,'state':'prepared'}
journalPath=evidence/'callback_recovery_journal.json'
journalPath.write_text(json.dumps(journal,indent=2)+'\n')
def recover():
    return ae('''set callbackValue to get processing done script
if (POSIX path of callbackValue) is "'''+installed+'''" then
set processing done script to ""
return "restored"
else
return "preserved-intervening-value"
end if''')
report={'initial':initial}
try:
    report['installation']=ae('set processing done script to "'+installed+'"\nreturn processing done script')
    # Installer exits here; recovery is invoked from a separate osascript process.
    for job,variant in [('job-callback-3','2'),('job-callback-4','12')]:
        p=subprocess.run(['python3',str(root/'probes/m0/run_probe.py'),str(root/'probes/m0/05_preview.applescript'),job,variant],capture_output=True,text=True,timeout=30)
        report.setdefault('exports',[]).append({'code':p.returncode,'out':p.stdout,'err':p.stderr})
    time.sleep(.2)
    report['callbacks']=[plistlib.load(p.open('rb')) for p in sorted(folder.glob('*.plist'))]
    report['recoverAfterInstallerExit']=recover()
    ae('set processing done script to "'+installed+'"')
    ae('set processing done script to "'+alternate+'"')
    report['recoverAfterInterveningChange']=recover()
    report['afterInterveningRecovery']=ae('return processing done script')
finally:
    # Both values are created by this test. Preserve any other intervening value.
    report['cleanup']=ae('''set nowValue to processing done script
if nowValue is not missing value then
if (POSIX path of nowValue) is "'''+installed+'" or (POSIX path of nowValue) is "'+alternate+'''" then set processing done script to ""
end if
return processing done script''')
    journal['state']='finished';journal['final']=report['cleanup']
    journalPath.write_text(json.dumps(journal,indent=2)+'\n')
    (evidence/'callback.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
