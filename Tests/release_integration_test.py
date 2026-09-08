#!/usr/bin/env python3
"""Run both live suites through an extracted archive, with build resource fallback unavailable.

Requires Capture One and C1_TEST_RAW_FIXTURE. Do not run concurrently with a build or another live suite.
"""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
archive = Path(sys.argv[1]).resolve()
assert os.environ.get('C1_TEST_RAW_FIXTURE'), 'Set C1_TEST_RAW_FIXTURE to a local RAW image'
expected = Path(str(archive) + '.sha256').read_text().split()[0]
assert hashlib.sha256(archive.read_bytes()).hexdigest() == expected
bundle = ROOT / '.build/release/c1_CaptureOneCore.bundle'
hidden = bundle.with_name('c1_CaptureOneCore.bundle.hidden-' + str(uuid.uuid4()))
with tempfile.TemporaryDirectory(prefix='c1-release-live-', dir='/private/tmp') as tmp:
    with tarfile.open(archive) as tf:
        for member in tf.getmembers():
            assert not member.name.startswith('/') and '..' not in Path(member.name).parts
        tf.extractall(tmp)
    root, = Path(tmp).iterdir()
    environment = dict(os.environ, C1_TEST_BIN=str(root / 'bin/c1'), C1_TEST_MCP_BIN=str(root / 'bin/c1-mcp'))
    moved = False
    try:
        if bundle.exists():
            bundle.rename(hidden)
            moved = True
        for script in ['contract_test.py', 'integration_test.py', 'mcp_test.py']:
            print(f'Running {script} using extracted binaries with build resources hidden', flush=True)
            subprocess.run([sys.executable, '-u', str(ROOT / 'Tests' / script)], env=environment,
                           cwd=tmp, check=True, timeout=600)
        print('PASS: extracted release CLI and MCP live suites; build resource fallback unavailable', flush=True)
    finally:
        if moved: hidden.rename(bundle)
