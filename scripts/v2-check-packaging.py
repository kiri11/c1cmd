#!/usr/bin/env python3
"""Live check of the packaged c1: doctor, a --document read and real results from the unzipped plugin.

Usage: C1_TEST_DOCUMENT_KIND=session scripts/v2-check-packaging.py --zip dist/c1-plugin.zip [--before <older c1next>]

On an owned disposable document holding a copy of --raw, it runs bin/c1 from the unzipped zip:
1. doctor passes, reports the zip's version and the document, and warns about nothing;
2. list reads the document's database with --document;
3. get matches --before (an older c1next that reads the live sdef) after nulls are left out;
4. get, get with changed, list and preview are captured compact and with --pretty, and their sizes reported.

Requires Capture One 16.8.5.30 with no open document. Calls run one at a time and only read. The document
closes when done and is kept with its evidence on failure. Never quits Capture One. Prints a JSON report.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Tests'))
from editing_fixture import EditingFixture  # noqa: E402


def without_nulls(value):
    if isinstance(value, dict):
        return {k: without_nulls(v) for k, v in value.items() if v is not None}
    if isinstance(value, list):
        return [without_nulls(v) for v in value]
    return value


def without_dehaze_color(value):
    """Capture One fills in a layer's dehaze color on its own (learned in step 2)."""
    if isinstance(value, dict):
        return {k: without_dehaze_color(v) for k, v in value.items() if k != 'dehaze color'}
    if isinstance(value, list):
        return [without_dehaze_color(v) for v in value]
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--zip', required=True)
    parser.add_argument('--raw', default=os.environ.get('C1_TEST_RAW_FIXTURE', os.path.expanduser('~/Desktop/papochka/TK7A7230.CR3')))
    parser.add_argument('--before', help='an older c1next whose get must match')
    args = parser.parse_args()
    events = []
    fixture = EditingFixture('v2-packaging', args.raw, lambda kind, data: events.append(dict(event=kind, **data)))
    evidence = fixture.base / 'packaging-evidence.json'
    report = dict(documentKind=fixture.kind, base=str(fixture.base))
    calls = []

    unzipped = fixture.base / 'plugin'
    subprocess.run(['unzip', '-q', str(Path(args.zip).resolve()), '-d', str(unzipped)], check=True)
    c1 = unzipped / 'c1-plugin' / 'bin' / 'c1'
    version = json.loads((unzipped / 'c1-plugin' / '.claude-plugin' / 'plugin.json').read_text())['version']
    env = dict(os.environ, C1_HOME=str(fixture.base / 'c1-home'), C1_CACHES=str(fixture.base / 'caches'))

    def cli(*argv):
        r = subprocess.run([str(ROOT / '.build/debug/c1'), *map(str, argv), '--format', 'json'], env=fixture.environment,
                           capture_output=True, text=True, timeout=300)
        assert r.returncode == 0, r.stdout + r.stderr
        return json.loads(r.stdout)

    def run(command, arguments, *flags, binary=c1):
        r = subprocess.run([str(binary), command, json.dumps(arguments), *flags], env=env, capture_output=True, text=True, timeout=900)
        calls.append(dict(binary=str(binary), command=command, arguments=arguments, flags=list(flags), exit=r.returncode,
                          stdout=r.stdout if r.returncode else None, stderr=r.stderr or None))
        assert r.returncode == 0, (command, r.stdout, r.stderr)
        return r.stdout

    try:
        variant = fixture.open(cli)[0]['id']
        doctor = json.loads(run('doctor', {}))
        report['doctor'] = doctor
        assert doctor['c1']['version'] == version, doctor
        assert doctor['document']['kind'] == fixture.kind and Path(doctor['document']['path']).resolve() == fixture.document, doctor
        assert doctor['captureOne'] == {'version': '16.8.5.30', 'tested': True}, doctor
        assert doctor['warnings'] == [], doctor

        # A new document's database can lag Capture One by up to a minute (learned in step 1).
        for attempt in range(40):
            listed = json.loads(run('list', {}, '--document', str(fixture.document)))
            if listed['variants']:
                break
            time.sleep(3)
        report['documentRead'] = dict(ids=[v['id'] for v in listed['variants']], waitedSeconds=attempt * 3)
        assert report['documentRead']['ids'] == [variant], listed

        get = json.loads(run('get', {'ids': [variant]}))
        if args.before:
            before = json.loads(run('get', {'ids': [variant]}, binary=args.before))
            same = without_dehaze_color(without_nulls(before)) == without_dehaze_color(get)
            report['getMatchesBefore'] = same
            assert same, 'get differs from the live-sdef c1next'

        sizes = {}
        for label, command, arguments in [('get', 'get', {'ids': [variant]}), ('get changed', 'get', {'ids': [variant], 'changed': True}),
                                          ('list', 'list', {}), ('preview', 'preview', {'id': variant, 'size': 800})]:
            compact = run(command, arguments)
            pretty = run(command, arguments, '--pretty')
            if command != 'preview':
                assert json.loads(compact) == json.loads(pretty), label
            sizes[label] = dict(compactBytes=len(compact.encode()), prettyBytes=len(pretty.encode()),
                                compactTokensEstimate=round(len(compact.encode()) / 4), prettyTokensEstimate=round(len(pretty.encode()) / 4))
            (fixture.base / f'{label.replace(" ", "-")}.compact.json').write_text(compact)
            (fixture.base / f'{label.replace(" ", "-")}.pretty.json').write_text(pretty)
        report['sizes'] = sizes
        assert sha_unchanged(fixture)
        fixture.close()
        report['closed'] = True
    except BaseException as error:
        report['error'] = repr(error)
        fixture.retain_and_close()
        report['retained'] = str(fixture.base)
        raise
    finally:
        evidence.write_text(json.dumps(dict(report=report, events=events, calls=calls), indent=2))
        report['evidence'] = str(evidence)
        print(json.dumps({k: v for k, v in report.items() if k != 'doctor'}, indent=2))


def sha_unchanged(fixture):
    from catalog_integration_test import sha
    return sha(fixture.raw) == sha(fixture.fixture) == fixture.original


if __name__ == '__main__':
    main()
