"""Controlled target pause: prove a timed-out Apple Event can execute later.

Only the fixed disposable clone is addressed. An independent watchdog resumes
Capture One after three seconds, in addition to the controller's finally block.
No mutation is retried.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[2]
def ae(body):
    p = subprocess.run(['osascript', '-s', 's', '-e',
        'tell application "/Applications/Capture One.app"\n' + body + '\nend tell'],
        capture_output=True, text=True, timeout=15)
    return {'code': p.returncode, 'out': p.stdout, 'err': p.stderr}

check = ae('return {id of document "c1-m0-1685-A.cosessiondb", exposure of adjustments of variant id "2" of document "c1-m0-1685-A.cosessiondb"}')
assert check['code'] == 0 and '"/private/tmp/c1-m0-1685-A"' in check['out'], check
pid = int(subprocess.check_output(['pgrep', '-x', 'Capture One'], text=True).strip())
command = subprocess.check_output(['ps', '-p', str(pid), '-o', 'comm='], text=True).strip()
assert command == '/Applications/Capture One.app/Contents/MacOS/Capture One', command
compiled = '/private/tmp/c1-m0-delayed-write.scpt'
subprocess.run(['osacompile', '-o', compiled, str(root/'probes/m0/10_delayed_write.applescript')], check=True)
watchdog = subprocess.Popen([sys.executable, '-c',
    'import os,signal,time,sys; time.sleep(3); os.kill(int(sys.argv[1]),signal.SIGCONT)', str(pid)])
start = time.perf_counter()
try:
    os.kill(pid, signal.SIGSTOP)
    p = subprocess.run(['osascript', compiled], capture_output=True, text=True, timeout=10)
finally:
    watchdog.wait(timeout=6)
    os.kill(pid, signal.SIGCONT)
time.sleep(0.5)
after = ae('return exposure of adjustments of variant id "2" of document "c1-m0-1685-A.cosessiondb"')
restore = ae('set exposure of adjustments of variant id "2" of document "c1-m0-1685-A.cosessiondb" to 0.25\nreturn exposure of adjustments of variant id "2" of document "c1-m0-1685-A.cosessiondb"')
report = {'before': check, 'targetPid': pid, 'targetExecutable': command,
          'fault': 'target SIGSTOP for 3 seconds; one-second Apple Event write deadline',
          'reply': {'code': p.returncode, 'out': p.stdout, 'err': p.stderr},
          'afterResume': after, 'restoration': restore,
          'seconds': time.perf_counter()-start}
(root/'docs/m0/16.8.5.30/timeout.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2))
