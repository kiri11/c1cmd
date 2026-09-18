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
}
DEFAULT_SUITES = ('cli', 'mcp', 'existing')


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--suites', nargs='+', choices=[*SUITES, 'all'], default=DEFAULT_SUITES,
                        help='Sequential live suites (default: cli mcp existing); all includes every regular matrix')
    args = parser.parse_args(argv)
    if 'all' in args.suites:
        if len(args.suites) != 1:
            parser.error('all must be used alone')
        args.suites = list(SUITES)
    if len(set(args.suites)) != len(args.suites):
        parser.error('duplicate suites would repeat live mutations')
    return args


def run(archive, suites):
    # Reject invalid selections before extracting files or contacting Capture One.
    if not suites or len(set(suites)) != len(suites) or any(name not in SUITES for name in suites):
        raise ValueError('Select unique known live suites')
    archive = Path(archive).resolve()
    raw = Path(os.environ.get('C1_TEST_RAW_FIXTURE', ''))
    if not raw.is_file():
        raise ValueError('Set C1_TEST_RAW_FIXTURE to an existing RAW image')
    raw = raw.resolve()
    print('Selected live suites: ' + ', '.join(suites), flush=True)
    skipped = [name for name in SUITES if name not in suites]
    print('Skipped live suites: ' + (', '.join(skipped) or 'none'), flush=True)
    bundle = ROOT / '.build/release/c1_CaptureOneCore.bundle'
    hidden = bundle.with_name('c1_CaptureOneCore.bundle.hidden-' + str(uuid.uuid4()))
    with tempfile.TemporaryDirectory(prefix='c1-release-live-', dir='/private/tmp') as tmp:
        root = extract_archive(archive, tmp)
        environment = dict(os.environ, C1_TEST_RAW_FIXTURE=str(raw),
                           C1_TEST_BIN=str(root / 'bin/c1'), C1_TEST_MCP_BIN=str(root / 'bin/c1-mcp'),
                           C1_TEST_CROP_EXAMPLE=str(root / 'examples/crop-proposals.py'),
                           C1_TEST_GRADE_EXAMPLE=str(root / 'examples/grade-folder.py'),
                           C1_INVENTORY_EVIDENCE=os.environ.get('C1_INVENTORY_EVIDENCE', str(Path(tmp) / 'inventory-evidence.json')))
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
            for name in suites:
                script, timeout = SUITES[name]
                print(f'Running {script} using extracted binaries with build resources hidden', flush=True)
                started = time.perf_counter()
                subprocess.run([sys.executable, '-B', '-u', str(ROOT / 'Tests' / script)], env=environment,
                               cwd=tmp, check=True, timeout=timeout)
                print(f'TIMING {script}: {time.perf_counter() - started:.3f}s', flush=True)
            print('PASS: selected packaged live suites: ' + ', '.join(suites), flush=True)
        finally:
            os.chdir(previous_directory)
            if moved:
                hidden.rename(bundle)


def main(argv=None):
    args = parse_args(argv)
    run(args.archive, args.suites)


if __name__ == '__main__':
    main()
