#!/usr/bin/env python3
"""Live smoke suite: reads, writes and viewing through the c1 in a plugin zip, on a disposable Session and Catalog.

Usage: C1_TEST_RAW_FIXTURE=<RAW> scripts/smoke.py --zip dist/c1-plugin.zip [--kinds session catalog]

For each document kind it opens an owned document holding a copy of the RAW, then runs the zip's bin/c1:
1. reads: doctor (the zip's version, the document, no warnings), list with and without --document, collections,
   selection, get and get with changed;
2. writes: set tone, rating and color tag, then rotation and a crop inside cropBounds; action layer.create,
   mask.fill and a layer's opacity; exposure on a photographer's layer, where luma.clear is refused; get shows
   each change; the first write takes a snapshot, revert restores the start and drops it, and the log holds every
   write;
3. viewing: preview at 800 px, a region, the full frame, crop_preview with two candidates, contact_sheet and
   thumb each write their image, and get is unchanged by them.

Requires Capture One 16.8.5.30 with no open document. Calls run one at a time. The originals are only copied.
Each document closes when done and is kept with its evidence on failure. Never quits Capture One.
Prints a JSON report; stops at the first failing kind and exits 1.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from fixture import ROOT, EditingFixture, apple

# Measured on 16.8.5.30: an untouched layer reports these as missing value, and after a revert as 0.
UNSET_LAYER_FIELDS = {'black recovery', 'brightness', 'clarity amount', 'clarity structure', 'contrast', 'dehaze amount', 'exposure',
                      'highlight recovery', 'moire amount', 'noise reduction details',
                      'noise reduction luminance', 'saturation', 'shadow recovery', 'sharpening amount', 'white recovery'}


def without(value, keys):
    if isinstance(value, dict):
        return {k: without(v, keys) for k, v in value.items() if k not in keys}
    if isinstance(value, list):
        return [without(v, keys) for v in value]
    return value


def comparable(state):
    # Capture One fills in a layer's dehaze color on its own, so a revert can't hold it fixed.
    state = without(state, {'route', 'dehaze color'})
    for layer in state['layers'][1:]:
        adjustments = layer.get('adjustments', {})
        for name in UNSET_LAYER_FIELDS & set(adjustments):
            if adjustments[name] == 0:
                del adjustments[name]
    return state


def image_size(path):
    out = subprocess.run(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(path)], capture_output=True, text=True, check=True).stdout
    values = dict(line.split(': ') for line in out.split('\n')[1:] if ': ' in line)
    return int(values['  pixelWidth']), int(values['  pixelHeight'])


class Smoke:
    def __init__(self, fixture, c1, version):
        self.fixture, self.c1, self.version = fixture, c1, version
        self.calls = []
        self.report = dict(kind=fixture.kind, base=str(fixture.base))

    def run(self, command, arguments=None, *flags):
        started = time.monotonic()
        r = subprocess.run([self.c1, command, json.dumps(arguments or {}), *flags], env=self.fixture.environment,
                           capture_output=True, text=True, timeout=900)
        self.calls.append(dict(command=command, arguments=arguments, flags=list(flags), exit=r.returncode,
                               seconds=round(time.monotonic() - started, 3), stdout=r.stdout if r.returncode else None,
                               stderr=r.stderr or None))
        assert r.returncode == 0, (command, arguments, r.stdout, r.stderr)
        return json.loads(r.stdout)

    def get(self, variant):
        state = self.run('get', {'ids': [variant]})['variants'][0]
        assert 'error' not in state, state
        return state

    def write(self, command, variant, arguments):
        item = self.run(command, dict(arguments, ids=[variant]))['variants'][0]
        assert item.get('outcome') == 'ok', item
        return item

    def image(self, label, result):
        path = Path(os.path.expanduser(result['path']))
        assert path.is_file(), (label, result)
        self.report.setdefault('images', {})[label] = dict(path=str(path), size=image_size(path))
        return image_size(path)

    def reads(self, variant):
        doctor = self.run('doctor')
        assert doctor['c1']['version'] == self.version, doctor
        assert doctor['document']['kind'] == self.fixture.kind, doctor
        assert Path(doctor['document']['path']).resolve() == self.fixture.document, doctor
        assert doctor['warnings'] == [], doctor
        assert [v['id'] for v in self.run('list')['variants']] == [variant]
        assert [v['id'] for v in self.run('list', {}, '--document', str(self.fixture.document))['variants']] == [variant]
        assert self.run('collections')['collections'], 'no collections'
        assert isinstance(self.run('selection')['ids'], list)
        start = self.get(variant)
        self.run('get', {'ids': [variant], 'changed': True})
        self.report['reads'] = 'ok'
        return start

    def writes(self, variant, start):
        self.write('set', variant, {'adjustments': {'exposure': 0.5, 'contrast': 10, 'highlight recovery': 20}, 'variant': {'rating': 4, 'color tag': 2}})
        self.write('set', variant, {'adjustments': {'rotation': 2}})
        rotated = self.get(variant)
        cx, cy, w, h = rotated['variant']['crop']
        crop = [cx, cy, round(w * 0.8), round(h * 0.8)]
        self.write('set', variant, {'variant': {'crop': crop}})
        layer = self.write('action', variant, {'action': 'layer.create', 'arguments': {'kind': 'adjustment', 'name': 'Smoke'}})['layer']
        self.write('action', variant, {'action': 'mask.fill', 'arguments': {'layer': layer}})
        self.write('set', variant, {'layers': [{'layer': layer, 'opacity': 60}]})
        self.write('set', variant, {'layers': [{'layer': 'Photographer', 'adjustments': {'exposure': 1, 'highlight recovery': 20}}]})
        refused = self.run('action', {'ids': [variant], 'action': 'luma.clear', 'arguments': {'layer': 'Photographer'}})['variants'][0]
        assert refused.get('error', {}).get('code') == 'refused', refused
        edited = self.get(variant)
        assert edited['adjustments']['exposure'] == 0.5 and edited['adjustments']['contrast'] == 10, edited['adjustments']
        assert edited['adjustments']['rotation'] == 2, edited['adjustments']['rotation']
        assert edited['adjustments']['highlight recovery'] == 20, edited['adjustments']
        assert all('highlight adjustment' not in l.get('adjustments', edited['adjustments']) for l in edited['layers']), 'get reports the alias'
        assert edited['variant']['rating'] == 4 and edited['variant']['color tag'] == 2, edited['variant']
        assert all(abs(a - b) <= 1 for a, b in zip(edited['variant']['crop'], crop)), (edited['variant']['crop'], crop)
        tagged = [l for l in edited['layers'] if l['name'].endswith(f'[{layer}]')]
        assert len(tagged) == 1 and tagged[0]['opacity'] == 60, edited['layers']
        photographer = [l for l in edited['layers'] if l['name'] == 'Photographer']
        assert photographer[0]['adjustments']['exposure'] == 1, photographer
        home = Path(self.fixture.environment['C1_HOME'])
        snapshots = f'documents/*/snapshots/{variant}.json'
        assert list(home.glob(snapshots)), 'no snapshot after the first write'
        self.write('revert', variant, {})
        reverted = self.get(variant)
        assert comparable(reverted) == comparable(start), 'revert did not restore the start'
        assert not list(home.glob(snapshots)), 'a successful revert keeps its snapshot'
        logs = list(home.glob('documents/*/log.jsonl'))
        assert len(logs) == 1 and len(logs[0].read_text().splitlines()) == 8, logs
        self.report['writes'] = 'ok'
        return reverted

    def viewing(self, variant, before):
        width, height = self.image('preview', self.run('preview', {'id': variant, 'size': 800}))
        assert max(width, height) == 800, (width, height)
        self.image('region', self.run('preview', {'id': variant, 'region': {'x': 0.25, 'y': 0.25, 'width': 0.5, 'height': 0.5}, 'scale': 0.5}))
        self.image('fullFrame', self.run('preview', {'id': variant, 'size': 800, 'fullFrame': True}))
        cx, cy, w, h = before['variant']['crop']
        candidates = [dict(centerX=cx, centerY=cy, width=round(w * f), height=round(h * f)) for f in (0.9, 0.7)]
        result = self.run('crop_preview', {'id': variant, 'candidates': candidates, 'size': 800})
        assert [c['number'] for c in result['candidates']] == [1, 2], result
        self.image('crop_preview', result)
        sheet = self.run('contact_sheet', {'ids': [variant], 'fillMissing': True})
        assert [t['status'] for t in sheet['tiles']] == ['shown'], sheet['tiles']
        self.image('contact_sheet', sheet)
        self.image('thumb', self.run('thumb', {'id': variant, 'maxSize': 400}))
        assert comparable(self.get(variant)) == comparable(before), 'viewing changed the variant'
        self.report['viewing'] = 'ok'


def run_kind(kind, c1, version, raw):
    events = []
    fixture = EditingFixture(f'smoke-{kind}', raw, c1, lambda name, data: events.append(dict(event=name, **data)), kind=kind)
    smoke = Smoke(fixture, c1, version)
    try:
        variant = fixture.open()[0]['id']
        # A photographer's layer, untouched and untagged, before c1's first write.
        fixture.assert_current()
        apple(f'make new layer at variant id {json.dumps(variant)} of current document with properties {{name:"Photographer", kind:adjustment}}')
        start = smoke.reads(variant)
        reverted = smoke.writes(variant, start)
        smoke.viewing(variant, reverted)
        assert fixture.originals_unchanged(), 'an original changed'
        fixture.close()
        smoke.report['closed'] = True
    except BaseException as error:
        smoke.report['error'] = repr(error)
        fixture.retain_and_close()
        smoke.report['retained'] = str(fixture.base)
    evidence = fixture.base / 'smoke-evidence.json'
    evidence.write_text(json.dumps(dict(report=smoke.report, events=events, calls=smoke.calls), indent=2))
    smoke.report['evidence'] = str(evidence)
    return smoke.report


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--zip', required=True)
    parser.add_argument('--kinds', nargs='+', choices=['session', 'catalog'], default=['session', 'catalog'])
    parser.add_argument('--raw', default=os.environ.get('C1_TEST_RAW_FIXTURE'))
    args = parser.parse_args()
    if not args.raw:
        parser.error('set C1_TEST_RAW_FIXTURE or pass --raw')
    unzipped = Path(tempfile.mkdtemp(prefix='c1-smoke-plugin-', dir=str(ROOT / '.build')))
    subprocess.run(['unzip', '-q', str(Path(args.zip).resolve()), '-d', str(unzipped)], check=True)
    c1 = str(unzipped / 'c1-plugin' / 'bin' / 'c1')
    version = json.loads((unzipped / 'c1-plugin' / '.claude-plugin' / 'plugin.json').read_text())['version']
    reports = []
    for kind in args.kinds:
        reports.append(run_kind(kind, c1, version, args.raw))
        if 'error' in reports[-1]:
            break
    passed = len(reports) == len(args.kinds) and not any('error' in r for r in reports)
    print(json.dumps(dict(passed=passed, version=version, reports=reports), indent=2))
    sys.exit(0 if passed else 1)


if __name__ == '__main__':
    main()
