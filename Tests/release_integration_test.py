#!/usr/bin/env python3
"""Run selected packaged live suites without build resources.

Defaults to CLI, MCP, and existing-variant workflows. Use --suites all for every
regular matrix; deliberate fault injection remains a separate command.
Requires Capture One and C1_TEST_RAW_FIXTURE. Never run beside a build or live suite.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid
from archive_test import extract_archive, check_package

ROOT = Path(__file__).resolve().parents[1]
SUITES = {
    'cli': ('integration_test.py', 600),
    'mcp': ('mcp_test.py', 600),
    'geometry': ('geometry_integration_test.py', 600),
    'lens': ('lens_geometry_integration_test.py', 1200),
    'perspective': ('perspective_geometry_integration_test.py', 1200),
    'keystone': ('keystone_integration_test.py', 600),
    'catalog': ('catalog_integration_test.py', 600),
    'existing': ('existing_variant_integration_test.py', 600),
    'inventory': ('inventory_integration_test.py', 600),
    'native': ('native_editing_integration_test.py', 1800),
    'recipes': ('recipe_integration_test.py', 1200),
    'read-workflow': ('read_workflow_integration_test.py', 900),
}
DEFAULT_SUITES = ('cli', 'mcp', 'existing')


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--suites', nargs='+', choices=[*SUITES, 'all'], default=DEFAULT_SUITES,
                        help='Sequential live suites (default: cli mcp existing); all includes every regular matrix')
    parser.add_argument('--document-kinds', nargs='+', choices=['session', 'catalog'], default=['session'],
                        help='Native/recipes fixture modes, run sequentially (default: session)')
    args = parser.parse_args(argv)
    if len(set(args.document_kinds)) != len(args.document_kinds):
        parser.error('duplicate document kinds would repeat live mutations')
    if 'all' in args.suites:
        if len(args.suites) != 1:
            parser.error('all must be used alone')
        args.suites = list(SUITES)
    if len(set(args.suites)) != len(args.suites):
        parser.error('duplicate suites would repeat live mutations')
    return args


def suite_runs(suites, document_kinds, layout):
    if not document_kinds or len(set(document_kinds)) != len(document_kinds) or any(k not in ("session", "catalog") for k in document_kinds):
        raise ValueError("Select unique session/catalog document kinds")
    if layout not in ("package", "unpackaged"):
        raise ValueError("Select package/unpackaged Catalog layout")
    return [(name, kind, f"{kind}-{layout}" if kind == "catalog" else kind)
            for name in suites for kind in (document_kinds if name in ("native", "recipes") else [None])]


def run(archive, suites, document_kinds=("session",)):
    # Reject invalid selections before extracting files or contacting Capture One.
    if not suites or len(set(suites)) != len(suites) or any(name not in SUITES for name in suites):
        raise ValueError('Select unique known live suites')
    runs = suite_runs(suites, document_kinds, os.environ.get('C1_TEST_CATALOG_LAYOUT', 'package'))
    archive = Path(archive).resolve()
    raw = Path(os.environ.get('C1_TEST_RAW_FIXTURE', ''))
    if not raw.is_file():
        raise ValueError('Set C1_TEST_RAW_FIXTURE to an existing RAW image')
    raw = raw.resolve()
    # The native suite covers both people-mask outcomes: the standard fixture has no people.
    people = Path(os.environ.get('C1_TEST_PEOPLE_FIXTURE', ''))
    if 'native' in suites and not people.is_file():
        raise ValueError('Set C1_TEST_PEOPLE_FIXTURE to an existing RAW image with people for the native suite')
    # Resolve caller-relative evidence paths before entering the temporary checkout.
    default_evidence = ROOT / '.build' / ('qualification-' + str(uuid.uuid4()))
    evidence_roots = {name: Path(os.environ.get(key, str(default_evidence / name))).resolve()
                      for name, key in [('native', 'C1_NATIVE_EVIDENCE'), ('recipes', 'C1_RECIPE_EVIDENCE')]
                      if name in suites}
    print('Selected live suites: ' + ', '.join(suites), flush=True)
    skipped = [name for name in SUITES if name not in suites]
    print('Skipped live suites: ' + (', '.join(skipped) or 'none'), flush=True)
    bundle = ROOT / '.build/release/c1_CaptureOneCore.bundle'
    hidden = bundle.with_name('c1_CaptureOneCore.bundle.hidden-' + str(uuid.uuid4()))
    with tempfile.TemporaryDirectory(prefix='c1-release-live-', dir='/private/tmp') as tmp:
        root = extract_archive(archive, tmp)
        environment = dict(os.environ, C1_TEST_RAW_FIXTURE=str(raw),
                           **({'C1_TEST_PEOPLE_FIXTURE': str(people.resolve())} if 'native' in suites else {}),
                           C1_TEST_BIN=str(root / 'bin/c1'), C1_TEST_MCP_BIN=str(root / 'bin/c1-mcp'),
                           C1_TEST_CROP_EXAMPLE=str(root / 'examples/crop-proposals.py'),
                           C1_TEST_GRADE_EXAMPLE=str(root / 'examples/grade-folder.py'),
                           C1_INVENTORY_EVIDENCE=os.environ.get('C1_INVENTORY_EVIDENCE', str(Path(tmp) / 'inventory-evidence.json')),
                           C1_READ_WORKFLOW_EVIDENCE=os.environ.get('C1_READ_WORKFLOW_EVIDENCE', str(Path(tmp) / 'read-workflow-evidence')))
        previous_directory = Path.cwd()
        moved = False
        try:
            os.chdir(tmp)
            if bundle.exists():
                bundle.rename(hidden)
                moved = True
            started = time.perf_counter()
            check_package(root)
            print(f'TIMING archive and contract: {time.perf_counter() - started:.3f}s', flush=True)
            for name, kind, label in runs:
                script, timeout = SUITES[name]
                suite_environment = dict(environment)
                if kind:
                    suite_environment['C1_TEST_DOCUMENT_KIND'] = kind
                    evidence_key = 'C1_NATIVE_EVIDENCE' if name == 'native' else 'C1_RECIPE_EVIDENCE'
                    suite_environment[evidence_key] = str(evidence_roots[name] / label)
                print(f'Running {script} ({label or "default"}) using extracted binaries with build resources hidden', flush=True)
                started = time.perf_counter()
                subprocess.run([sys.executable, '-B', '-u', str(ROOT / 'Tests' / script)], env=suite_environment,
                               cwd=tmp, check=True, timeout=timeout)
                print(f'TIMING {script}: {time.perf_counter() - started:.3f}s', flush=True)
            print('PASS: selected packaged live suites: ' + ', '.join(suites), flush=True)
        finally:
            os.chdir(previous_directory)
            if moved:
                hidden.rename(bundle)


def main(argv=None):
    args = parse_args(argv)
    run(args.archive, args.suites, args.document_kinds)


if __name__ == '__main__':
    main()
