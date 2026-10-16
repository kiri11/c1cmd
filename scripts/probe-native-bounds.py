#!/usr/bin/env python3
"""Confirm the native bounds table on an owned disposable Session: write each bound and just past it.

c1 rejects out-of-range values before dispatch, so the writes go through direct AppleScript on the
fixture's variant, each guarded by the document-id check. c1 only opens the fixture and supplies its
identity. Requires zero open documents (C1_TEST_RAW_FIXTURE names the RAW to copy). Never quits
Capture One; closes only its own document, and keeps the fixture and evidence on failure.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Tests'))
from catalog_integration_test import CLI, apple, sha
from editing_fixture import EditingFixture

TABLE = ROOT / 'sdef/16.8.5.30.native-bounds.json'
REGISTRY = ROOT / 'Sources/CaptureOneCore/Resources/NativeEditing.json'
LAYER_NAME = 'c1 bounds probe'
CONTEXT = {'adjustments': 'adjustments of v',
           'layer': f'(first layer of v whose name is {json.dumps(LAYER_NAME)})',
           'lens': 'lens correction of v'}
TOLERANCE = {'tint': .01, 'temperature': .1}
PARTNER = {'highlight': 'shadow', 'shadow': 'highlight'}


def step(kind, low, high):
    return 1 if kind == 'integer' or high - low >= 20 else .01


def close(field, actual, expected):
    if actual is None:
        return False
    distance = abs(actual - expected)
    if field.endswith(' hue'):
        distance = min(distance % 360, 360 - distance % 360)
    return distance <= TOLERANCE.get(field, 1e-4)


def classify(field, at, past):
    """A bound holds when writing it reads it back and writing just past it does not."""
    if at['error'] is not None or not close(field, at['readBack'], at['written']):
        return 'mismatch'
    if close(field, past['readBack'], past['written']):
        return 'mismatch'
    return 'confirmed' if past['error'] is not None else 'confirmed-clamped'


def partner(field):
    """The level field whose value can constrain this one: 'level shadow rgb' for 'level highlight rgb'."""
    words = field.split()
    for i, word in enumerate(words):
        if words[0] == 'level' and word in PARTNER:
            return ' '.join(words[:i] + [PARTNER[word]] + words[i + 1:])
    return None


def literal(value):
    value = float(value)
    return str(int(value)) if value.is_integer() else repr(round(value, 6))


def number(text):
    return None if text == 'missing value' else float(text)


class Variant:
    """Direct AppleScript on one variant of the expected open document."""

    def __init__(self, document_id, variant_id):
        self.guard = (f'if (count of documents) is not 1 then error "Document changed"\n'
                      f'set d to current document\n'
                      f'if (id of d as text) is not {json.dumps(document_id)} then error "Document changed"\n'
                      f'set v to variant id {json.dumps(variant_id)} of d\n')

    def run(self, line):
        try:
            return apple(self.guard + line), None
        except AssertionError as error:
            text = str(error).strip()
            if 'Document changed' in text:
                raise
            return None, text

    def read(self, scope, field):
        out, error = self.run(f'return {field} of {CONTEXT[scope]}')
        assert error is None, (scope, field, error)
        return number(out)

    def write(self, scope, field, value):
        _, error = self.run(f'set {field} of {CONTEXT[scope]} to {literal(value)}')
        return dict(written=value, readBack=self.read(scope, field), error=error)


def probe(variant, scope, field, kind, low, high):
    s = step(kind, low, high)
    original = variant.read(scope, field)
    other = partner(field)
    writes = dict(min=variant.write(scope, field, low), max=variant.write(scope, field, high),
                  belowMin=variant.write(scope, field, round(low - s, 6)),
                  aboveMax=variant.write(scope, field, round(high + s, 6)))
    restore = variant.write(scope, field, original)
    return dict(scope=scope, field=field, kind=kind, bounds=[low, high], step=s, original=original,
                partner=other and dict(field=other, value=variant.read(scope, other)),
                writes=writes, restore=restore, restored=close(field, restore['readBack'], original),
                minBound=classify(field, writes['min'], writes['belowMin']),
                maxBound=classify(field, writes['max'], writes['aboveMax']))


def render(rows):
    width = max(len(r['field']) for r in rows)
    lines = [f'{"field".ljust(width)}  {"bounds":<16} {"min":<18} {"max":<18} past min / past max']
    for r in rows:
        past = ' / '.join(f"{w['written']}->{w['readBack']}{' err' if w['error'] else ''}"
                          for w in (r['writes']['belowMin'], r['writes']['aboveMax']))
        lines.append(f'{r["field"].ljust(width)}  {str(r["bounds"]):<16} {r["minBound"]:<18} {r["maxBound"]:<18} {past}')
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--evidence', type=Path, help='evidence directory (default: <fixture base>/evidence)')
    parser.add_argument('--table', type=Path, default=TABLE)
    args = parser.parse_args()
    table = json.loads(args.table.read_text())
    kinds = {(scope, f['name']): f['type'] for scope, fields in json.loads(REGISTRY.read_text()).items() for f in fields}
    raw = Path(os.environ['C1_TEST_RAW_FIXTURE']).resolve()
    original = sha(raw)
    assert apple('return count of documents') == '0', 'Close documents before probing'
    assert json.loads(apple('return version')) == table['build'], 'Table build differs from the running Capture One'
    record = dict(build=table['build'], table=str(args.table), source=table['source'], events=[], fields=[])
    def log(name, value):
        record['events'].append(dict(event=name, value=value))
    owned = EditingFixture('bounds', raw, log)
    evidence = (args.evidence or owned.base / 'evidence').resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    path = evidence / 'native-bounds.json'
    def save():
        path.write_text(json.dumps(record, indent=2) + '\n')
    def cli(*argv):
        r = subprocess.run([str(CLI), *map(str, argv), '--format', 'json'], env=owned.environment,
                           capture_output=True, text=True, timeout=180)
        assert r.returncode == 0, r.stderr
        return json.loads(r.stdout)
    try:
        variants = owned.open(cli)
        doc = cli('doc', 'info')
        variant = Variant(doc['documentId'], variants[0]['id'])
        variant.run(f'make new layer at v with properties {{name:{json.dumps(LAYER_NAME)}, kind:adjustment}}')
        assert variant.run(f'return count of (layers of v whose name is {json.dumps(LAYER_NAME)})') == ('1', None)
        for scope, fields in table['bounds'].items():
            for field, (low, high) in fields.items():
                row = probe(variant, scope, field, kinds[(scope, field)], low, high)
                record['fields'].append(row)
                save()
                print(f"{field}: {row['minBound']} / {row['maxBound']}", flush=True)
                assert row['restored'], (field, row['original'], row['restore'])
        assert sha(raw) == sha(owned.fixture) == original, 'RAW changed'
        owned.close()
    except BaseException:
        owned.retain_and_close()
        save()
        raise
    rows = record['fields']
    mismatches = [r['field'] for r in rows if 'mismatch' in (r['minBound'], r['maxBound'])]
    record['summary'] = dict(fields=len(rows), mismatches=mismatches, rawSHA256=original, fixture=str(owned.base))
    save()
    print(render(rows))
    print(f'{len(mismatches)} mismatched of {len(rows)}; evidence {path}')
    return 1 if mismatches else 0


if __name__ == '__main__':
    sys.exit(main())
