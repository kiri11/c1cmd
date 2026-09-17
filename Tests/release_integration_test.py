#!/usr/bin/env python3
"""Run contract, tonal and geometry suites through an extracted archive without build resources.

Requires Capture One and C1_TEST_RAW_FIXTURE. Do not run concurrently with a build or another live suite.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid
import time
from archive_test import extract_archive, check_package

ROOT = Path(__file__).resolve().parents[1]
archive = Path(sys.argv[1]).resolve()
assert os.environ.get('C1_TEST_RAW_FIXTURE'), 'Set C1_TEST_RAW_FIXTURE to a local RAW image'
bundle = ROOT / '.build/release/c1_CaptureOneCore.bundle'
hidden = bundle.with_name('c1_CaptureOneCore.bundle.hidden-' + str(uuid.uuid4()))
with tempfile.TemporaryDirectory(prefix='c1-release-live-', dir='/private/tmp') as tmp:
    root = extract_archive(archive, tmp)
    os.chdir(tmp)
    environment = dict(os.environ, C1_TEST_BIN=str(root / 'bin/c1'), C1_TEST_MCP_BIN=str(root / 'bin/c1-mcp'), C1_TEST_CROP_EXAMPLE=str(root / 'examples/crop-proposals.py'), C1_TEST_GRADE_EXAMPLE=str(root / 'examples/grade-folder.py'), C1_INVENTORY_EVIDENCE=os.environ.get('C1_INVENTORY_EVIDENCE', str(Path(tmp) / 'inventory-evidence.json')))
    moved = False
    try:
        if bundle.exists():
            bundle.rename(hidden)
            moved = True
        started = time.perf_counter()
        check_package(root)
        print(f'TIMING archive and contract: {time.perf_counter() - started:.3f}s', flush=True)
        for script in ['integration_test.py', 'mcp_test.py', 'geometry_integration_test.py', 'lens_geometry_integration_test.py', 'catalog_integration_test.py', 'existing_variant_integration_test.py', 'inventory_integration_test.py']:
            print(f'Running {script} using extracted binaries with build resources hidden', flush=True)
            started = time.perf_counter()
            subprocess.run([sys.executable, '-u', str(ROOT / 'Tests' / script)], env=environment,
                           cwd=tmp, check=True, timeout=1200 if script == 'lens_geometry_integration_test.py' else 600)
            print(f'TIMING {script}: {time.perf_counter() - started:.3f}s', flush=True)
        print('PASS: extracted release CLI and MCP live suites; build resource fallback unavailable', flush=True)
    finally:
        if moved: hidden.rename(bundle)
