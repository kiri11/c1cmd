#!/usr/bin/env python3
"""Read-only stored-vs-live Catalog benchmark. Open the matching disposable Catalog first.

No concurrent AppleScript calls. Concurrent SQL readers use independent processes.
This measures command startup too and checks stored/live parity on every repetition.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import hashlib
from datetime import datetime, timezone
from pathlib import Path
import statistics
import subprocess
import time

ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--database',required=True)
p.add_argument('--cli',default=str(ROOT/'.build/debug/c1'))
p.add_argument('--repeats',type=int,default=7)
p.add_argument('--output',required=True)
a=p.parse_args()
assert a.repeats>=3

def run(args):
    start=time.perf_counter()
    result=subprocess.run([a.cli,*args],capture_output=True,text=True,timeout=30)
    elapsed=time.perf_counter()-start
    if result.returncode: raise RuntimeError(result.stderr)
    return json.loads(result.stdout),elapsed

def sql(): return run(['catalog','variants','--database',a.database])
def native(): return run(['variants','list','--format','json'])
def norm_sql(value):
    return [(str(r['variantDatabaseID']),r['name'],str(Path(r['originalPath']).resolve()),r['rating'],r['colorTag']) for r in value['variants']]
def norm_native(value):
    return [(r['id'],r['name'],str(Path(r['parentImagePath']).resolve()),r['rating'],r['colorTag']) for r in value]

doc,_=run(['doc','info','--format','json'])
assert not doc['isSession']
assert Path(a.database).resolve().parent==Path(doc['documentPath']).resolve()
expected=norm_native(native()[0]); assert expected
samples={'sqlite':[],'applescript':[]}
for i in range(a.repeats):
    for name,call,normalize in [('sqlite',sql,norm_sql),('applescript',native,norm_native)][::1 if i%2==0 else -1]:
        data,elapsed=call(); assert normalize(data)==expected,(name,data,expected)
        samples[name].append(elapsed)
parallel={}
for workers in [1,2,4]:
    start=time.perf_counter()
    with ThreadPoolExecutor(workers) as pool: results=list(pool.map(lambda _:sql(),range(12)))
    assert all(norm_sql(data)==expected for data,_ in results)
    parallel[str(workers)]={'requests':12,'wallSeconds':time.perf_counter()-start}
end,_=run(['doc','info','--format','json']); assert end['openToken']==doc['openToken']
report={'observedAt':datetime.now(timezone.utc).isoformat(),'cliSHA256':hashlib.sha256(Path(a.cli).read_bytes()).hexdigest(),'database':str(Path(a.database).resolve()),'appVersion':doc['appVersion'],'variantCount':len(expected),
        'samplesSeconds':samples,'medianSeconds':{k:statistics.median(v) for k,v in samples.items()},
        'sqliteConcurrency':parallel,'parityFields':['databaseID vs native ID (fixture only)','name','originalPath','rating','colorTag'],
        'limitations':['Stored/live equality at observation time is not a freshness guarantee.','No native concurrent calls: supported Capture One workflow is sequential.','CLI startup is included. Small-fixture results do not establish large-Catalog scaling.']}
report['speedup']=report['medianSeconds']['applescript']/report['medianSeconds']['sqlite']
Path(a.output).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
