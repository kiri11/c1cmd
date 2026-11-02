#!/usr/bin/env python3
"""Live check of curves and the color editor in c1 get, set and revert.

Usage: C1_TEST_DOCUMENT_KIND=session|catalog scripts/check-editor.py [--before <older c1>] [--runs 7]

On an owned disposable document holding a copy of --raw, it:
1. edits the background and two layers: a photographer's layer made with raw AppleScript, untagged, with its
   own curve, and a layer c1 created; then checks that `get` matches per-field AppleScript reads of every curve
   point and color correction on each;
2. takes a snapshot, changes all five curves and basic and advanced corrections on the background and the c1
   layer, adds an advanced correction to one and deletes one from the other, reverts, and checks that `get`
   equals the snapshot field for field and that the photographer's layer never changed;
3. times `get` with 0 and 2 layers (median of --runs, against --before too when given), `set` and `revert`.

Requires Capture One 16.8.5.30 with no open document. Calls run one at a time. The document closes when done
and is kept with its evidence on failure. Never quits Capture One. Prints a JSON report.
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
from fixture import EditingFixture

CHANNELS = ['rgb', 'luma', 'red', 'green', 'blue']
BASIC = ['hue change', 'saturation change', 'lightness change']
ADVANCED = ['enabled', 'red', 'green', 'blue', 'hue start', 'hue end', 'saturation start', 'saturation end',
            'smoothness', 'hue change', 'saturation change', 'lightness change']
PHOTOGRAPHER_CURVE = [[0, 10], [50, 60], [100, 90]]
TOLERANCE = 1e-4


def same(a, b):
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return abs(a - b) <= TOLERANCE * max(1, abs(a), abs(b))
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    return a == b


def differences(a, b, path=''):
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for key in sorted(set(a) | set(b)):
            out += differences(a.get(key), b.get(key), f'{path}.{key}' if path else key)
        return out
    if isinstance(a, list) and isinstance(b, list) and len(a) == len(b) and all(isinstance(x, dict) for x in a + b):
        return [d for i, (x, y) in enumerate(zip(a, b)) for d in differences(x, y, f'{path}.{i}')]
    return [] if same(a, b) else [dict(path=path, expected=a, actual=b)]


class Live:
    def __init__(self, fixture, variant, c1, before):
        self.fixture, self.variant, self.c1, self.before = fixture, variant, c1, before
        self.home = fixture.base / 'c1-home'
        self.setup_home = fixture.base / 'c1-home-setup'
        self.calls = []

    def run(self, command, arguments, home=None, binary=None):
        env = dict(os.environ, C1_HOME=str(home or self.home))
        started = time.monotonic()
        r = subprocess.run([binary or self.c1, command, json.dumps(arguments)], env=env, capture_output=True, text=True, timeout=600)
        elapsed = time.monotonic() - started
        self.calls.append(dict(command=command, arguments=arguments, home=str(home or self.home), seconds=round(elapsed, 3), exit=r.returncode))
        assert r.returncode == 0, (command, arguments, r.stdout, r.stderr)
        return json.loads(r.stdout), elapsed

    def get(self, binary=None):
        result, elapsed = self.run('get', {'ids': [self.variant]}, binary=binary)
        state = result['variants'][0]
        assert 'error' not in state, state
        return state, elapsed

    def one(self, command, arguments, home=None):
        result, elapsed = self.run(command, dict(arguments, ids=[self.variant]), home=home)
        item = result['variants'][0]
        assert item.get('outcome') == 'ok', item
        return item, elapsed

    def apple(self, body):
        guard = ('tell application "Capture One"\n'
                 f'if (id of current document as text) is not {json.dumps(self.fixture.native_id)} then error "Document changed"\n'
                 f'set v to variant id {json.dumps(self.variant)} of {self.container}\n')
        r = subprocess.run(['osascript', '-s', 's', '-e', guard + body + '\nend tell'], capture_output=True, text=True, timeout=600)
        assert r.returncode == 0, r.stderr
        return json.loads(r.stdout.replace('{', '[').replace('}', ']').replace('missing value', 'null'))

    def raw_editor(self, layer):
        """Every curve point and color correction field of a layer (1 is the background), each read by its own Apple Event."""
        a = 'adjustments of v' if layer == 1 else f'adjustments of layer {layer} of v'
        lines = ['set out to {}']
        for channel in CHANNELS:
            curve = f'{channel} curve of {a}'
            lines += ['set pts to {}', f'repeat with k from 1 to count of curve points of {curve}',
                      f'set end of pts to {{brightness of curve point k of {curve}, amount of curve point k of {curve}}}',
                      'end repeat', 'set end of out to pts']
        basic = f'basic color correction k of color editor settings of {a}'
        lines += ['set cs to {}', f'repeat with k from 1 to count of basic color corrections of color editor settings of {a}',
                  f'set end of cs to {{name of {basic}, {", ".join(f"{f} of {basic}" for f in BASIC)}}}', 'end repeat', 'set end of out to cs']
        advanced = f'advanced color correction k of color editor settings of {a}'
        lines += ['set cs to {}', f'repeat with k from 1 to count of advanced color corrections of color editor settings of {a}',
                  f'set end of cs to {{{", ".join(f"{f} of {advanced}" for f in ADVANCED)}}}', 'end repeat', 'set end of out to cs',
                  'return out']
        items = self.apple('\n'.join(lines))
        return dict(curves=dict(zip(CHANNELS, items[:5])),
                    colorEditor=dict(basic=[dict(zip(['name'] + BASIC, c)) for c in items[5]],
                                     advanced=[dict(zip(ADVANCED, c)) for c in items[6]]))


def editor_patch(curve, basic, hue):
    return {'curves': {channel: curve for channel in CHANNELS},
            # Capture One refuses any lightness change on "all".
            'colorEditor': {'basic': [{'name': name, 'hue change': hue, 'saturation change': hue * 2,
                                       **({} if name == 'all' else {'lightness change': -hue})} for name in basic],
                            'advanced': [{'index': 0, 'hue change': hue, 'saturation change': 12}]}}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--raw', default=os.path.expanduser('~/Desktop/papochka/TK7A7230.CR3'))
    parser.add_argument('--c1', default=str(ROOT / '.build/debug/c1'))
    parser.add_argument('--before', help='an older c1 to time get against')
    parser.add_argument('--runs', type=int, default=7)
    args = parser.parse_args()
    events = []
    fixture = EditingFixture('editor', args.raw, args.c1, lambda kind, data: events.append(dict(event=kind, **data)))
    evidence = fixture.base / 'editor-evidence.json'
    report = dict(documentKind=fixture.kind, base=str(fixture.base))
    live = None


    def timing(label, binary=None):
        times = [live.get(binary)[1] for _ in range(args.runs)]
        report.setdefault('getSeconds', {})[label] = dict(median=round(statistics.median(times), 3), runs=[round(t, 3) for t in times])

    try:
        variant = fixture.open()[0]['id']
        live = Live(fixture, variant, args.c1, args.before)
        state, _ = live.get()
        # The route c1 took; a Session's fallback scans favorites, and the Capture folder is the current collection.
        route = state['route']
        live.container = (f'collection id {json.dumps(route.split()[-1])} of current document' if route.startswith(('collection', 'all images'))
                          else 'current document')
        assert state['adjustments']['curves'] == {c: [[0, 0], [100, 100]] for c in CHANNELS}, state['adjustments']['curves']
        assert state['adjustments']['colorEditor']['advanced'] == [], 'a new variant has no advanced corrections'
        report['untouched'] = dict(curve=state['adjustments']['curves']['rgb'], basic=[c['name'] for c in state['adjustments']['colorEditor']['basic']])
        for label, binary in [('after, 0 layers', None)] + ([('before, 0 layers', args.before)] if args.before else []):
            timing(label, binary)

        # The photographer's layer: raw AppleScript, no tag, its own curve.
        live.apple('set l to make new layer at v with properties {name:"Photographer", kind:adjustment}\n'
                   'tell rgb curve of adjustments of l\n'
                   'set amount of first curve point to 10\nset amount of last curve point to 90\n'
                   'make new curve point with properties {brightness:50, amount:60}\nend tell\nreturn 0')
        # c1's layer and an edited starting state, written under another home so the checked snapshot comes later.
        created, _ = live.one('action', {'action': 'layer.create', 'arguments': {'name': 'Edit'}}, home=live.setup_home)
        tag = created['layer']
        for layer in (0, tag):
            live.one('action', {'action': 'color.create', 'arguments': {'layer': layer}}, home=live.setup_home)
            live.one('action', {'action': 'color.create', 'arguments': {'layer': layer}}, home=live.setup_home)
        start = editor_patch([[0, 4], [30, 25], [70, 80], [100, 96]], ['red', 'all'], 6)
        start['colorEditor']['advanced'] = [{'index': 0, 'red': 200, 'green': 120, 'blue': 40, 'hue start': -25, 'hue end': 30, 'hue change': 8},
                                            {'index': 1, 'red': 30, 'green': 60, 'blue': 220, 'hue change': -10, 'saturation change': 15}]
        live.one('set', {'adjustments': start, 'layers': [{'layer': tag, 'adjustments': start}]}, home=live.setup_home)

        # 1. get against per-field reads.
        edited, _ = live.get()
        layers = edited['layers']
        assert [l['name'] for l in layers] == ['Background', 'Photographer', f'Edit [{tag}]'], [l['name'] for l in layers]
        mismatches = {}
        for index, bulk in [(1, edited['adjustments']), (2, layers[1]['adjustments']), (3, layers[2]['adjustments'])]:
            raw = live.raw_editor(index)
            got = dict(curves=bulk['curves'], colorEditor=bulk['colorEditor'])
            found = differences(raw, got)
            if found:
                mismatches[index] = found
        report['getMatchesPerFieldReads'] = dict(ok=not mismatches, mismatches=mismatches,
                                                 advancedCounts=[len(edited['adjustments']['colorEditor']['advanced']),
                                                                 len(layers[2]['adjustments']['colorEditor']['advanced'])])
        photographer = layers[1]['adjustments']
        assert same(photographer['curves']['rgb'], PHOTOGRAPHER_CURVE), photographer['curves']['rgb']
        for label, binary in [('after, 2 layers', None)] + ([('before, 2 layers', args.before)] if args.before else []):
            timing(label, binary)

        # 2. Round trip: the first write takes the snapshot; revert restores it.
        snapshot_state = edited
        change = editor_patch([[0, 0], [20, 35], [60, 50], [100, 100]], ['red', 'orange', 'all'], -9)
        change['colorEditor']['advanced'].append({'index': 1, 'red': 90, 'hue end': 45, 'smoothness': 25})
        result, set_seconds = live.one('set', {'adjustments': change, 'layers': [{'layer': tag, 'adjustments': change}]})
        report['setSeconds'] = round(set_seconds, 3)
        report['setWarnings'] = result.get('warnings', [])
        _, create_seconds = live.one('action', {'action': 'color.create', 'arguments': {}})
        _, delete_seconds = live.one('action', {'action': 'color.delete', 'arguments': {'layer': tag, 'color': 0}})
        report['actionSeconds'] = dict(create=round(create_seconds, 3), delete=round(delete_seconds, 3))
        changed, _ = live.get()
        assert len(changed['adjustments']['colorEditor']['advanced']) == 3
        assert len(changed['layers'][2]['adjustments']['colorEditor']['advanced']) == 1
        assert not differences(photographer, changed['layers'][1]['adjustments']), 'the photographer layer changed during set'
        snapshot = json.loads((live.home / 'documents').glob('*/snapshots/*.json').__next__().read_text())
        report['snapshot'] = dict(hasCurves='curves' in snapshot['state']['adjustments'], hasColorEditor='colorEditor' in snapshot['state']['adjustments'],
                                  skinTone=snapshot.get('skinTone'))
        reverted, revert_seconds = live.one('revert', {})
        report['revertSeconds'] = round(revert_seconds, 3)
        report['revertResult'] = {k: reverted.get(k) for k in ('notRestored', 'warnings', 'errors', 'layers') if k in reverted}
        after, _ = live.get()
        ignored = []
        found = []
        for d in differences({k: v for k, v in snapshot_state.items() if k != 'route'}, {k: v for k, v in after.items() if k != 'route'}):
            # Capture One fills in a layer's dehaze color on its own (learned in step 2).
            (ignored if d['path'].endswith('dehaze color') else found).append(d)
        report['roundTrip'] = dict(ok=not found, differences=found, ignored=ignored)
        report['photographerUntouched'] = not differences(photographer, after['layers'][1]['adjustments'])
        fixture.close()
        report['closed'] = True
    except BaseException:
        fixture.retain_and_close()
        report['retained'] = str(fixture.base)
        raise
    finally:
        evidence.write_text(json.dumps(dict(report=report, events=events, calls=live.calls if live else []), indent=2))
        report['evidence'] = str(evidence)
        print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
