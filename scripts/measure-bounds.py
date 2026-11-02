#!/usr/bin/env python3
"""Measure the accepted range of every numeric field c1 v2 writes, live, and write Sources/C1Kit/Resources/Bounds.json.

A value is accepted when writing it raises no error and reads back as written; Capture One clamps some
values silently and names the wrong limit for others, so only the read-back counts. Each side of a range
starts from the previous table's bound when there is one and confirms it (accepted at the bound, refused one
step past it); otherwise it searches outward by powers of ten and bisects. A side still accepted at 1e6 is
recorded as unbounded.

Runs on an owned disposable document (C1_TEST_DOCUMENT_KIND=session|catalog, default session) holding a
copy of --raw (default $C1_TEST_RAW_FIXTURE). Requires Capture One 16.8.5.30 with no open document. Calls run one at a time, the fixture
closes when done, and on failure it is kept with its evidence. Never quits Capture One.
"""
import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
from fixture import EditingFixture

SDEF = '/Applications/Capture One.app/Contents/Resources/CaptureOne.sdef'
OUTPUT = ROOT / 'Sources/C1Kit/Resources/Bounds.json'
SEEDS = ROOT / 'sdef/16.8.5.30.native-bounds.json'
LAYER = 'c1 bounds probe'
# Section, sdef class, the owner expression, and the fields considered (None: every writable numeric one).
SECTIONS = [
    ('adjustments', 'adjustment settings', '«property vset» of v', None),
    ('lensCorrection', 'lens correction settings', '«property vlns» of v', None),
    ('variant', 'variant', 'v', {'rating', 'color tag'}),
    ('layer', 'layer', f'(first layer of v whose name is "{LAYER}")', {'opacity'}),
    ('basicColor', 'basic color correction', 'basic color correction "red" of color editor settings of «property vset» of v', None),
    # A new correction picks no color; its ranges are measured around that, so a range Capture One narrows
    # around another color is still refused there.
    ('advancedColor', 'advanced color correction', 'advanced color correction 1 of color editor settings of «property vset» of v', None),
]
ORIENTATIONS = [0, 90, 180, 270]
# Lens facts of the image's own lens, not settings: a fixed lens accepts only its focal length, and tilt
# and shift only with a tilt-shift lens. They stay out of the table, so c1 does not write them.
LENS_FACTS = {'aperture', 'focal length', 'tilt', 'tilt direction', 'shift', 'shift direction'}
LIMIT = 1e6


def numeric_fields():
    tree = ET.parse(SDEF)
    classes = {}
    for c in tree.iter('class'):
        for p in c.iter('property'):
            if p.get('access') == 'r':
                continue
            classes.setdefault(c.get('name'), {}).setdefault(p.get('name'), (p.get('code'), p.get('type')))
    for section, cls, owner, allowed in SECTIONS:
        for name, (code, kind) in sorted(classes[cls].items()):
            if kind in ('real', 'integer', 'RGB color') and (allowed is None or name in allowed) \
                    and not (section == 'lensCorrection' and name in LENS_FACTS):
                yield section, owner, name, code, kind


class Probe:
    def __init__(self, document_id, variant_id, log):
        self.guard = ('tell application "/Applications/Capture One.app"\n'
                      f'if (id of current document as text) is not {json.dumps(document_id)} then error "Document changed"\n'
                      f'set v to variant id {json.dumps(variant_id)} of current document\n')
        self.log = log

    def run(self, body):
        r = subprocess.run(['osascript', '-s', 's', '-e', self.guard + body + '\nend tell'], capture_output=True, text=True, timeout=150)
        if 'Document changed' in r.stderr:
            raise RuntimeError('The open document changed')
        if r.returncode and ('-1712' in r.stderr or '-609' in r.stderr or '-600' in r.stderr):
            raise RuntimeError(r.stderr.strip())
        return (r.stdout.strip(), None) if r.returncode == 0 else (None, r.stderr.strip())

    def read(self, owner, code):
        out, error = self.run(f'return «property {code}» of {owner}')
        assert error is None, (owner, code, error)
        return json.loads(out.replace('{', '[').replace('}', ']')) if out != 'missing value' else None

    def accepts(self, owner, code, value, kind):
        literal = '{%s}' % ', '.join([literal_number(value)] * 3) if kind == 'RGB color' else literal_number(value)
        _, error = self.run(f'set «property {code}» of {owner} to {literal}')
        stored = self.read(owner, code)
        if kind == 'RGB color':
            ok = error is None and stored == [value] * 3
        else:
            ok = error is None and stored is not None and abs(stored - value) <= 0.004 + 1e-6 * abs(value)
        self.log.append(dict(owner=owner, code=code, written=value, stored=stored, error=error, accepted=ok))
        return ok


def literal_number(value):
    return str(int(value)) if float(value).is_integer() else repr(round(value, 6))


def side(probe, owner, code, kind, origin, direction, seed):
    """The last accepted value going `direction` (+1 or -1) from `origin`, or None when unbounded."""
    step = 1 if kind != 'real' else 0.01
    if seed is not None and probe.accepts(owner, code, seed, kind) and not probe.accepts(owner, code, seed + direction * step, kind):
        return seed
    good, bad = origin, None
    distance = 1
    while distance <= LIMIT:
        candidate = origin + direction * distance
        if probe.accepts(owner, code, candidate, kind):
            good = candidate
            distance *= 10
        else:
            bad = candidate
            break
    if bad is None:
        return None
    while abs(bad - good) > step * 1.5:
        middle = (good + bad) / 2
        middle = round(middle) if kind != 'real' else round(middle, 2)
        if middle in (good, bad):
            break
        if probe.accepts(owner, code, middle, kind):
            good = middle
        else:
            bad = middle
    nice = round(good) if kind != 'real' else round(good, 1)
    if nice != good and abs(nice - good) < 0.06 and probe.accepts(owner, code, nice, kind):
        good = nice
    return good


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--raw', default=os.environ.get('C1_TEST_RAW_FIXTURE'))
    parser.add_argument('--output', type=Path, default=OUTPUT)
    parser.add_argument('--no-seeds', action='store_true', help='search every side instead of confirming the previous table')
    parser.add_argument('--only', nargs='+', metavar='SECTION.FIELD',
                        help='measure only these fields and merge them into the existing table')
    args = parser.parse_args()
    if not args.raw:
        parser.error('set C1_TEST_RAW_FIXTURE or pass --raw')
    seeds = {} if args.no_seeds else json.loads(SEEDS.read_text())['bounds']
    seed_sections = {'adjustments': 'adjustments', 'lensCorrection': 'lens', 'layer': 'layer'}
    events = []
    fixture = EditingFixture('bounds', args.raw, ROOT / '.build/debug/c1', lambda kind, data: events.append(dict(event=kind, **data)))
    probes = []
    evidence = fixture.base / 'bounds-evidence.json'


    try:
        variant = fixture.open()[0]['id']
        document = json.loads(subprocess.check_output(['osascript', '-s', 's', '-e',
                                                      'tell application "/Applications/Capture One.app" to return id of current document as text'], text=True))
        probe = Probe(document, variant, probes)
        probe.run(f'make new layer of v with properties {{name:"{LAYER}", kind:adjustment}}')
        probe.run('make new advanced color correction at color editor settings of «property vset» of v')
        version = json.loads(probe.run('return version')[0])
        fields = json.loads(args.output.read_text())['fields'] if args.only else {}
        codes = {(section, name): code for section, _, name, code, _ in numeric_fields()}
        for section, owner, name, code, kind in numeric_fields():
            if args.only and f'{section}.{name}' not in args.only:
                continue
            # A colour balance hue reads back only while its saturation is above zero.
            partner = name.replace(' hue', ' saturation') if name.startswith('color balance') and name.endswith(' hue') else None
            if partner:
                partner_origin = probe.read(owner, codes[(section, partner)])
                probe.run(f'set «property {codes[(section, partner)]}» of {owner} to 0.5')
            origin = probe.read(owner, code)
            if kind == 'RGB color':
                if probe.accepts(owner, code, 0, kind) and probe.accepts(owner, code, 65535, kind) and not probe.accepts(owner, code, 65536, kind):
                    fields.setdefault(section, {})[name] = dict(min=0, max=65535)
                probe.run(f'set «property {code}» of {owner} to {{{", ".join(map(str, origin))}}}')
                continue
            if origin is None or not probe.accepts(owner, code, origin, kind):
                print('unwritable', section, name, flush=True)
                continue
            if section == 'adjustments' and name == 'orientation':
                if all(probe.accepts(owner, code, value, kind) for value in ORIENTATIONS) and not probe.accepts(owner, code, 45, kind):
                    fields.setdefault(section, {})[name] = dict(values=ORIENTATIONS)
            else:
                seed = seeds.get(seed_sections.get(section, ''), {}).get(name)
                low = side(probe, owner, code, kind, origin, -1, seed[0] if seed else None)
                high = side(probe, owner, code, kind, origin, +1, seed[1] if seed else None)
                fields.setdefault(section, {})[name] = dict(min=low, max=high)
            assert probe.accepts(owner, code, origin, kind), ('restore failed', section, name, origin)
            if partner:
                probe.run(f'set «property {codes[(section, partner)]}» of {owner} to {literal_number(partner_origin)}')
            print(section, name, fields.get(section, {}).get(name), flush=True)
        table = dict(build=version, measured=datetime.now(timezone.utc).isoformat(timespec='seconds'),
                     method='scripts/measure-bounds.py: accepted means no error and the value reads back as written',
                     document=fixture.kind, fields=fields)
        args.output.write_text(json.dumps(table, indent=2, sort_keys=True) + '\n')
        fixture.close()
        print('wrote', args.output, 'evidence', evidence)
    except BaseException:
        fixture.retain_and_close()
        print('retained', fixture.base)
        raise
    finally:
        evidence.write_text(json.dumps(dict(events=events, probes=probes), indent=2))


if __name__ == '__main__':
    main()
