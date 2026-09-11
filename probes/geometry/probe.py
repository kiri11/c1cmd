#!/usr/bin/env python3
"""Exact-build crop/rotation exploration on a c1-managed clone of a copied RAW.

Usage: probe.py RAW EVIDENCE_DIR. Requires zero open documents. Stops on any
uncertain write, leaving the durable c1 journal block and Session for inspection.
"""
import datetime, hashlib, json, os, shutil, subprocess, sys, tempfile, time, uuid
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / '.build/debug/c1'
raw, evidence = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
evidence.mkdir(parents=True, exist_ok=False)

def log(kind, **values):
    with (evidence / 'events.jsonl').open('a') as f:
        f.write(json.dumps(dict(event=kind, **values)) + '\n'); f.flush(); os.fsync(f.fileno())
def apple(body):
    p = subprocess.run(['osascript', '-s', 's', '-e', 'tell application "/Applications/Capture One.app"\n' + body + '\nend tell'], capture_output=True, text=True, timeout=90)
    if p.returncode: raise RuntimeError(p.stderr)
    return json.loads(p.stdout.replace('{', '[').replace('}', ']').replace('missing value', 'null'))
def cli(*args):
    p = subprocess.run([str(BIN), *args, '--format', 'json'], capture_output=True, text=True, timeout=100)
    if p.returncode: raise RuntimeError(p.stderr)
    return json.loads(p.stdout)
def checksum(p): return hashlib.sha256(p.read_bytes()).hexdigest()
assert apple('return count of documents') == 0
assert apple('return version') == '16.8.5.30'
base = Path(tempfile.mkdtemp(prefix='c1-geometry-probe-', dir='/private/tmp'))
apple(f'make new document with properties {{name:"geometry", kind:session, path:"{base}"}}\nreturn true')
session = base / 'geometry'
fixture = session / 'Capture' / raw.name
shutil.copy2(raw, fixture)
apple('set current collection of current document to collection "Capture" of current document\nreturn true')
for _ in range(30):
    variants = cli('variants', 'list')
    if variants: break
    time.sleep(.5)
assert cli('doctor')['allChecksPassed']
doc = cli('doc', 'info'); source = variants[0]['id']; initial = cli('get', source)
clone = cli('variant', 'clone', source); ref = clone['workingRef']; vid = clone['cloneVariantId']
journal = session / '.c1/journal.jsonl'
binding = json.loads(journal.read_text().splitlines()[0])
def read(target):
    return apple(f'''set v to variant id "{target}" of current document
set a to adjustments of v
set lc to lens correction of v
return {{crop of v, rotation of a, orientation of a, flip of a as text, crop aspect ratio of v, dimensions of parent image of v, maximum crop v apply false, {{keystone amount of a, keystone vertical of a, keystone horizontal of a, keystone skew of a, keystone aspect of a}}, {{distortion of lc, lens profile of lc as text}}, crop outside image of v}}''')
original = read(source)
log('environment', session=str(session), rawSHA256=checksum(raw), original=original, clone=clone, doc=doc)

def write(label, body):
    # Record before dispatch in the application's normal unresolved-write journal.
    cli('get', ref)
    op = dict(binding, operationId=str(uuid.uuid4()), operationType='geometry-probe', workingRef=ref, nativeVariantId=vid, status='pending', timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat())
    def append():
        with journal.open('a') as f: f.write(json.dumps(op)+'\n'); f.flush(); os.fsync(f.fileno())
    append(); log('pending', label=label, operationId=op['operationId'], before=read(vid), script=body)
    try:
        apple(f'set v to variant id "{vid}" of current document\n' + body + '\nreturn true')
        after=read(vid)
        assert cli('get', source)['stateHash'] == initial['stateHash']
        assert read(source) == original
        assert checksum(fixture) == checksum(raw)
        op['status']='succeeded'; append(); log('observed', label=label, after=after)
    except BaseException as e:
        op['status']='outcome-unknown'; op['error']=str(e); append(); log('failure', label=label, error=str(e)); raise

log('read', geometry=read(vid))
write('rotation-plus-5', 'set rotation of adjustments of v to 5')
write('rotation-minus-5', 'set rotation of adjustments of v to -5')
write('rotation-zero', 'set rotation of adjustments of v to 0')
write('crop-3x2', 'set crop of v to {3000, 2000, 4500, 3000}')
write('crop-3x4', 'set crop of v to {3000, 2000, 2400, 3200}')
write('rotate-cropped', 'set rotation of adjustments of v to 5')
write('off-center', 'set crop of v to {2800, 2000, 2100, 2800}')
write('orientation-90', 'set rotation of adjustments of v to 0\nset orientation of adjustments of v to 90')
write('orientation-180', 'set orientation of adjustments of v to 180')
write('orientation-270', 'set orientation of adjustments of v to 270')
write('orientation-0', 'set orientation of adjustments of v to 0')
log('finished', rawSHA256=checksum(fixture), sourceStateHash=cli('get', source)['stateHash'])
cli('variant', 'delete', ref)
apple('close current document\nreturn true')
print(evidence)
