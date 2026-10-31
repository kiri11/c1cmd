#!/usr/bin/env python3
"""Time variant lookup routes against Catalog size on an owned disposable Catalog.

Creates a Catalog under .build, imports one copied RAW as the target, then grows the
Catalog with small JPEG copies. At each size it times reading the same adjustment
properties through each route, plus an end-to-end `c1 get`. Calls are sequential.
The source RAW is copied, never imported or written; the fixture is retained.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Tests'))
os.environ['C1_TEST_DOCUMENT_KIND'] = 'catalog'
from catalog_integration_test import ROOT  # noqa: E402
from editing_fixture import EditingFixture  # noqa: E402

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--raw', required=True)
p.add_argument('--sizes', default='0,1000,4000', help='Filler JPEG counts, cumulative targets')
p.add_argument('--samples', type=int, default=3)
p.add_argument('--fields', type=int, default=10, help='Adjustment properties read per sample')
p.add_argument('--cli', default=str(ROOT / '.build/debug/c1'))
p.add_argument('--output', required=True)
a = p.parse_args()

FIELDS = [f['name'] for f in json.load(open(ROOT / 'Sources/CaptureOneCore/Resources/NativeEditing.json'))['adjustments']
          if f['type'] in ('real', 'integer')][:a.fields]
events = []


def log(kind, data):
    events.append(dict(kind=kind, at=datetime.now(timezone.utc).isoformat(), **data))
    print(kind, json.dumps(data), flush=True)


def timed_script(body, timeout=900):
    """Run body inside a Capture One tell block; return the in-script seconds it reports."""
    script = ('use framework "Foundation"\nuse scripting additions\n'
              'on now()\nreturn (current application\'s NSDate\'s timeIntervalSinceReferenceDate()) as real\nend now\n'
              'tell application "/Applications/Capture One.app"\nset d to current document\n'
              f'{body}\nend tell')
    r = subprocess.run(['osascript', '-s', 's', '-e', script], capture_output=True, text=True, timeout=timeout)
    if r.returncode:
        raise RuntimeError(r.stderr.strip())
    return json.loads(r.stdout.strip())


def apple(body):
    r = subprocess.run(['osascript', '-s', 's', '-e', f'tell application "/Applications/Capture One.app"\n{body}\nend tell'],
                       capture_output=True, text=True, timeout=900)
    if r.returncode:
        raise RuntimeError(r.stderr.strip())
    return r.stdout.strip()


fixture = EditingFixture('probe-routes', a.raw, log)


def cli(*args):
    r = subprocess.run([a.cli, *args, '--format', 'json'], capture_output=True, text=True, timeout=900, env=fixture.environment)
    if r.returncode:
        raise RuntimeError(r.stdout + r.stderr)
    return json.loads(r.stdout)


def reads(spec):
    """Per-field reads through spec, the way the handlers read them."""
    lines = '\n'.join(f'set end of vals to ({name} of adj)' for name in FIELDS)
    return (f'set t0 to my now()\nset v to {spec}\nset adj to adjustments of v\nset vals to {{}}\n{lines}\n'
            'return (my now()) - t0')


def bulk(spec):
    return f'set t0 to my now()\nset v to {spec}\nset r to properties of adjustments of v\nreturn (my now()) - t0'


def exists_only(spec):
    return f'set t0 to my now()\nset r to exists {spec}\nreturn (my now()) - t0'


try:
    variants = fixture.open(cli)
    vid = variants[0]['id']
    all_images = json.loads(apple('return id of first collection of current document whose name is "All Images" and kind is smart album and user is false'))
    album = json.loads(apple('set c to make new collection of current document with properties {name:"c1-probe-album", kind:album}\n'
                             f'add inside c variants {{variant id "{vid}" of collection id "{all_images}" of current document}}\n'
                             'return id of c'))
    routes = {
        'allImages': f'variant id "{vid}" of collection id "{all_images}" of d',
        'album': f'variant id "{vid}" of collection id "{album}" of d',
    }
    filler_dir = fixture.base / 'filler'
    filler_dir.mkdir()
    seed = fixture.base / 'seed.jpg'
    subprocess.run(['sips', '-s', 'format', 'jpeg', '-Z', '96', str(fixture.fixture), '--out', str(seed)], check=True, capture_output=True)
    made = 0
    results = []
    for target in [int(s) for s in a.sizes.split(',')]:
        if target > made:
            batch = fixture.base / f'filler-{target}'
            batch.mkdir()
            for i in range(made, target):
                shutil.copyfile(seed, batch / f'f{i:06d}.jpg')
            fixture.import_referenced(batch)
            deadline = time.time() + 3600
            while True:
                count = int(apple(f'return count of variants of collection id "{all_images}" of current document'))
                if count >= target + 1:
                    break
                assert time.time() < deadline, ('import stalled', count, target)
                time.sleep(10)
            made = target
            time.sleep(30)  # let import post-processing settle
        count = int(apple(f'return count of variants of collection id "{all_images}" of current document'))
        row = dict(variants=count, fields=len(FIELDS), seconds={})
        cases = {f'{name}-{kind}': fn(spec) for name, spec in routes.items()
                 for kind, fn in [('exists', exists_only), ('perField', reads), ('bulk', bulk)]}
        apple(f'set current collection of current document to collection id "{album}" of current document')
        cases['currentCollection-perField'] = reads(f'variant id "{vid}" of d')
        for i in range(a.samples):
            for case, body in (cases.items() if i % 2 == 0 else reversed(list(cases.items()))):
                try:
                    row['seconds'].setdefault(case, []).append(timed_script(body))
                except RuntimeError as e:
                    row['seconds'].setdefault(case, []).append(None)
                    row.setdefault('errors', {})[case] = str(e)
            start = time.perf_counter()
            cli('get', vid)
            row['seconds'].setdefault('c1Get', []).append(time.perf_counter() - start)
        row['median'] = {k: statistics.median([x for x in v if x is not None]) for k, v in row['seconds'].items() if any(x is not None for x in v)}
        log('size', row)
        results.append(row)
    fixture.close()
    log('closed', dict(base=str(fixture.base)))
except BaseException:
    fixture.retain_and_close()
    raise
finally:
    Path(a.output).parent.mkdir(parents=True, exist_ok=True)
    Path(a.output).write_text(json.dumps(dict(fields=FIELDS, fixture=fixture.details(), events=events), indent=2))
