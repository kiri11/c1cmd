#!/usr/bin/env python3
"""Live check of c1next preview, crop_preview, contact_sheet and thumb.

Usage: C1_TEST_DOCUMENT_KIND=session|catalog scripts/v2-check-viewing.py [--before <older c1next>] [--runs 5]

On an owned disposable document holding a copy of --raw, it:
1. records what `export crop method: ignore` renders on a variant rotated 5° with a tight crop, against
   `maximum crop`, and checks that a candidate cut from that full frame matches the same rectangle exported
   after `set` (then puts the crop back);
2. checks that reconfiguring c1-preview, or a write, right after `process` returns leaves the queued export alone;
3. checks that a region at scale 1 matches the same area of the 1500 px overview;
4. checks that `get` is identical before and after every preview kind, and that revert restores the start;
5. adds 19 more photos and times (median of --runs) previews at 800 and 1500, full frame, a region at 100%,
   crop_preview cold and cached, a 20-photo contact sheet page, thumb through ImageIO and an exiftool
   extraction for comparison, and `get` against --before.

Requires Capture One 16.8.5.30 with no open document. Calls run one at a time. The document closes when done
and is kept with its evidence on failure. Never quits Capture One. Prints a JSON report.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Tests'))
from editing_fixture import EditingFixture  # noqa: E402
from preview_mapping import pixels  # noqa: E402

ROTATION = 5
TIGHT = [2900, 2100, 2400, 1600]
CANDIDATE = {'centerX': 3000, 'centerY': 2200, 'width': 2100, 'height': 1400}
REGION = {'x': 0.4, 'y': 0.35, 'width': 0.2, 'height': 0.2}


def compare(a, a_rect, b, margin=0.15):
    """Mean absolute channel error between rectangle a_rect of image a and all of image b, searching a's
    displacement over ±4 of a's pixels. Samples skip `margin` at the top left, where crop_preview draws its number."""
    aw, ah, ap = a
    bw, bh, bp = b
    x0, y0, w, h = a_rect
    grid = [(margin + (0.95 - margin) * i / 59, margin + (0.95 - margin) * j / 59) for i in range(60) for j in range(60)]

    def error(dx, dy):
        values = []
        for u, v in grid:
            values.extend(abs(p - q) for p, q in zip(ap(x0 + u * w + dx, y0 + v * h + dy), bp(u * bw, v * bh)))
        return sum(values) / len(values)
    shifted = {(dx, dy): error(dx, dy) for dx in range(-4, 5) for dy in range(-4, 5)}
    best = min(shifted, key=shifted.get)
    result = dict(meanAbsoluteChannelError=round(shifted[0, 0], 2), bestOffset=best,
                  displacedRatio=round(shifted[0, 0] / min(e for s, e in shifted.items() if max(map(abs, s)) == 4), 3),
                  unrelatedRatio=round(shifted[0, 0] / error(w * 0.3, h * 0.2), 3))
    result['ok'] = max(map(abs, best)) <= 1 and result['displacedRatio'] < 0.85 and result['unrelatedRatio'] < 0.5
    return result


class Live:
    def __init__(self, fixture, c1next):
        self.fixture, self.c1next = fixture, c1next
        self.home = fixture.base / 'c1-home'
        self.calls = []

    def run(self, command, arguments, binary=None, ok=True):
        env = dict(os.environ, C1_HOME=str(self.home))
        started = time.monotonic()
        r = subprocess.run([binary or self.c1next, command, json.dumps(arguments)], env=env, capture_output=True, text=True, timeout=900)
        elapsed = time.monotonic() - started
        self.calls.append(dict(command=command, arguments=arguments, seconds=round(elapsed, 3), exit=r.returncode,
                               output=r.stdout if r.returncode else None))
        if ok:
            assert r.returncode == 0, (command, arguments, r.stdout, r.stderr)
        return json.loads(r.stdout), elapsed

    def get(self, variant, binary=None):
        result, elapsed = self.run('get', {'ids': [variant]}, binary=binary)
        state = result['variants'][0]
        assert 'error' not in state, state
        return without_dehaze_color({k: v for k, v in state.items() if k != 'route'}), elapsed

    def write(self, command, variant, arguments):
        result, _ = self.run(command, dict(arguments, ids=[variant]))
        item = result['variants'][0]
        assert item.get('outcome') == 'ok', item
        return item

    def apple(self, body):
        r = subprocess.run(['osascript', '-s', 's', '-e', 'tell application "Capture One"\n'
                            f'if (id of current document as text) is not {json.dumps(self.fixture.native_id)} then error "Document changed"\n'
                            + body + '\nend tell'], capture_output=True, text=True, timeout=600)
        assert r.returncode == 0, r.stderr
        return r.stdout.strip()


def without_dehaze_color(value):
    """Capture One fills in a layer's dehaze color on its own (learned in step 2)."""
    if isinstance(value, dict):
        return {k: without_dehaze_color(v) for k, v in value.items() if k != 'dehaze color'}
    if isinstance(value, list):
        return [without_dehaze_color(v) for v in value]
    return value


def median(times):
    return dict(median=round(statistics.median(times), 3), runs=[round(t, 3) for t in times])


def wait_for(path, seconds=180):
    deadline, last = time.time() + seconds, None
    while time.time() < deadline:
        size = path.stat().st_size if path.exists() else 0
        if size and size == last:
            return True
        last = size
        time.sleep(0.25)
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--raw', default=os.environ.get('C1_TEST_RAW_FIXTURE', os.path.expanduser('~/Desktop/papochka/TK7A7230.CR3')))
    parser.add_argument('--more', default=os.path.expanduser('~/Desktop/papochka'), help='a folder of RAWs; 19 are copied for the contact sheet')
    parser.add_argument('--c1next', default=str(ROOT / '.build/debug/c1next'))
    parser.add_argument('--before', help='an older c1next to time get against')
    parser.add_argument('--runs', type=int, default=5)
    args = parser.parse_args()
    events = []
    fixture = EditingFixture('v2-viewing', args.raw, lambda kind, data: events.append(dict(event=kind, **data)))
    evidence = fixture.base / 'viewing-evidence.json'
    report = dict(documentKind=fixture.kind, base=str(fixture.base), timings={})
    live = None

    def cli(*argv):
        r = subprocess.run([str(ROOT / '.build/debug/c1'), *map(str, argv), '--format', 'json'], env=fixture.environment,
                           capture_output=True, text=True, timeout=300)
        assert r.returncode == 0, r.stdout + r.stderr
        return json.loads(r.stdout)

    def unchanged(label, variant, before, call):
        result = call()
        after, _ = live.get(variant)
        report.setdefault('getUnchanged', {})[label] = after == before
        assert after == before, f'{label} changed the variant'
        return result

    try:
        variant = fixture.open(cli)[0]['id']
        live = Live(fixture, args.c1next)
        recipes_before = set(json.loads(live.apple('return name of every recipe of current document').replace('{', '[').replace('}', ']')))
        start, _ = live.get(variant)
        route = live.run('get', {'ids': [variant]})[0]['variants'][0]['route']
        container = (f'collection id {json.dumps(route.split()[-1])} of current document' if route.startswith(('collection', 'all images'))
                     else 'current document')
        vref = f'variant id {json.dumps(variant)} of {container}'

        # get before and after reading maximum crop only for corrections.
        for label, binary in [('after', None)] + ([('before', args.before)] if args.before else []):
            report['timings'][f'get ({label})'] = median([live.get(variant, binary)[1] for _ in range(args.runs)])

        # 1. What a full frame renders on a rotated, tightly cropped variant.
        live.write('set', variant, {'adjustments': {'rotation': ROTATION}})
        live.write('set', variant, {'variant': {'crop': TIGHT}})
        rotated, _ = live.get(variant)
        native = live.apple(f'set v to {vref}\nreturn {{dimensions of parent image of v, maximum crop v apply false, crop of v}}')
        full = unchanged('fullFrame', variant, rotated, lambda: live.run('preview', {'id': variant, 'fullFrame': True})[0])
        mapping = full['fullFrame']['mapping']
        report['fullFrame'] = dict(native=native, result=full,
                                   renderedArea=dict(left=mapping['left'], top=mapping['top'], width=full['width'] / mapping['scale'],
                                                     height=full['height'] / mapping['scale']))
        composite = unchanged('crop_preview', variant, rotated,
                              lambda: live.run('crop_preview', {'id': variant, 'candidates': [CANDIDATE], 'size': 1500})[0])
        tile = composite['candidates'][0]['rect']
        live.write('set', variant, {'variant': {'crop': [CANDIDATE[k] for k in ('centerX', 'centerY', 'width', 'height')]}})
        after_set = live.run('preview', {'id': variant, 'size': 1500})[0]
        report['candidateMatchesSetCrop'] = compare(pixels(composite['path']), (tile['x'], tile['y'], tile['width'], tile['height']),
                                                    pixels(after_set['path']))
        live.write('set', variant, {'variant': {'crop': TIGHT}})
        assert live.get(variant)[0] == rotated, 'putting the crop back restores the rotated state'

        # 2 and 3. Reconfiguring the recipe, or writing, in the same script right after process returns.
        out = fixture.base / 'races'
        out.mkdir()

        def recipe(edge, name):
            return (f'tell recipe "c1-preview" of current document\nset primary scaling value to {edge}\n'
                    f'set root folder location to POSIX file {json.dumps(str(out))}\nset output name format to {json.dumps(name)}\n'
                    'set export crop method to respect\nend tell\n')
        live.apple(f'set v to {vref}\n' + recipe(800, 'reconfigured-first') + 'set j to process v recipe "c1-preview"\n'
                   + recipe(300, 'reconfigured-second') + 'return j')
        live.apple(f'set v to {vref}\n' + recipe(800, 'write-baseline') + 'return process v recipe "c1-preview"')
        assert wait_for(out / 'write-baseline.jpg')
        exposure = live.apple(f'return exposure of adjustments of {vref}')
        live.apple(f'set v to {vref}\n' + recipe(800, 'write-raced') + 'set j to process v recipe "c1-preview"\n'
                   'set exposure of adjustments of v to 2\nreturn j')
        assert wait_for(out / 'write-raced.jpg') and wait_for(out / 'reconfigured-first.jpg')
        live.apple(f'set exposure of adjustments of {vref} to {exposure}')
        time.sleep(5)
        sizes = {p.stem: pixels(p)[:2] for p in sorted(out.glob('*.jpg'))}
        baseline, raced = pixels(out / 'write-baseline.jpg'), pixels(out / 'write-raced.jpg')
        report['races'] = dict(sizes=sizes, reconfigureChangedExport=sizes.get('reconfigured-first') != (800, 533),
                               writeAfterProcess=compare(baseline, (0, 0, baseline[0], baseline[1]), raced, margin=0.05))
        report['races']['writeChangedExport'] = report['races']['writeAfterProcess']['meanAbsoluteChannelError'] > 3
        assert live.get(variant)[0] == rotated, 'the race checks restore exposure'

        # 4. A region at scale 1 against the overview.
        overview = unchanged('preview', variant, rotated, lambda: live.run('preview', {'id': variant, 'size': 1500})[0])
        region = unchanged('region', variant, rotated, lambda: live.run('preview', {'id': variant, 'region': REGION})[0])
        o = pixels(overview['path'])
        report['regionMatchesOverview'] = dict(region=region, comparison=compare(
            o, (REGION['x'] * o[0], REGION['y'] * o[1], REGION['width'] * o[0], REGION['height'] * o[1]), pixels(region['path']), margin=0.05))

        # 5. Timings on the rotated variant.
        def timed(label, arguments, command='preview', before=None):
            times = []
            for _ in range(args.runs):
                if before:
                    before()
                times.append(live.run(command, arguments)[1])
            report['timings'][label] = median(times)
        timed('preview 800', {'id': variant, 'size': 800})
        timed('preview 1500', {'id': variant, 'size': 1500})
        timed('preview full frame 1500', {'id': variant, 'fullFrame': True})
        timed('preview region at 100%', {'id': variant, 'region': REGION})
        frames = Path(full['path']).parent
        timed('crop_preview cold', {'id': variant, 'candidates': [CANDIDATE]}, 'crop_preview',
              before=lambda: [p.unlink() for p in frames.glob(f'frame-{variant}-*.jpg')])
        timed('crop_preview cached', {'id': variant, 'candidates': [CANDIDATE]}, 'crop_preview')
        report['cropPreviewCached'] = live.run('crop_preview', {'id': variant, 'candidates': [CANDIDATE]})[0]['cached']

        reverted = live.write('revert', variant, {})
        report['revert'] = {k: reverted.get(k) for k in ('notRestored', 'warnings', 'errors') if k in reverted}
        end, _ = live.get(variant)
        report['revertRestoresStart'] = end == start

        # 20 photos for the contact sheet; thumbnails appear once Capture One has seen the files.
        more = sorted(p for p in Path(args.more).glob('*.CR3') if p.resolve() != Path(args.raw).resolve())[:19]
        for source in more:
            if fixture.kind == 'session':
                shutil.copy2(source, fixture.fixture.parent / source.name)
            else:
                copy = fixture.base / source.name
                shutil.copy2(source, copy)
                fixture.import_referenced(copy)
        # Capture One builds thumbnails lazily, for what its browser has shown, so some may stay missing.
        deadline, shown = time.time() + 300, []
        while time.time() < deadline:
            sheet = live.run('contact_sheet', {})[0]
            shown.append(sum(t['status'] == 'shown' for t in sheet['tiles']))
            if len(sheet['tiles']) == 20 and (shown[-1] == 20 or (len(shown) > 10 and len(set(shown[-5:])) == 1)):
                break
            time.sleep(3)
        report['contactSheet'] = dict(path=sheet.get('path'), size=[sheet.get('width'), sheet.get('height')], shownOverTime=shown,
                                      statuses=[t['status'] for t in sheet['tiles']], crops=[t.get('crop') for t in sheet['tiles']])
        assert len(sheet['tiles']) == 20, sheet
        timed('contact_sheet 20 photos', {}, 'contact_sheet')

        timed('thumb (ImageIO) 1500', {'id': variant}, 'thumb')
        timed('thumb (ImageIO) full size', {'id': variant, 'maxSize': 8192}, 'thumb')
        report['thumb'] = live.run('thumb', {'id': variant})[0]
        exif = []
        for _ in range(args.runs):
            started = time.monotonic()
            subprocess.run(['exiftool', '-b', '-JpgFromRaw', str(fixture.fixture)], capture_output=True, check=True)
            exif.append(time.monotonic() - started)
        report['timings']['exiftool -JpgFromRaw extraction only'] = median(exif)

        report['recipesAdded'] = sorted(set(json.loads(live.apple('return name of every recipe of current document')
                                                       .replace('{', '[').replace('}', ']'))) - recipes_before)
        assert all(name.startswith('c1-') for name in report['recipesAdded']), report['recipesAdded']
        failed = [k for k in ('candidateMatchesSetCrop',) if not report[k]['ok']]
        failed += ['regionMatchesOverview'] if not report['regionMatchesOverview']['comparison']['ok'] else []
        failed += [k for k in ('reconfigureChangedExport', 'writeChangedExport') if report['races'][k]]
        failed += ['revertRestoresStart'] if not report['revertRestoresStart'] else []
        report['failed'] = failed
        assert not failed, failed
        fixture.close()
        report['closed'] = True
    except BaseException as error:
        report['error'] = repr(error)
        fixture.retain_and_close()
        report['retained'] = str(fixture.base)
        raise
    finally:
        evidence.write_text(json.dumps(dict(report=report, events=events, calls=live.calls if live else []), indent=2))
        report['evidence'] = str(evidence)
        print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
