#!/usr/bin/env python3
"""Test exactly the archive layout, from an unrelated working directory."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
from contract_test import run

archive = Path(sys.argv[1]).resolve()
expected = Path(str(archive) + '.sha256').read_text().split()[0]
assert hashlib.sha256(archive.read_bytes()).hexdigest() == expected
with tempfile.TemporaryDirectory(prefix='c1-archive-') as tmp:
    with tarfile.open(archive) as tf:
        for member in tf.getmembers():
            assert not member.name.startswith('/') and '..' not in Path(member.name).parts
        tf.extractall(tmp)
    root, = Path(tmp).iterdir()
    binary = root / 'bin'
    script = binary / 'c1_CaptureOneCore.bundle' / 'Contents' / 'Resources' / 'Handlers.applescript'
    if not script.exists(): script = binary / 'c1_CaptureOneCore.bundle' / 'Handlers.applescript'
    assert script.is_file(), 'Missing runtime AppleScript resource'
    os.chdir(tmp)
    run(binary / 'c1', binary / 'c1-mcp')
    result = subprocess.run([str(binary / 'c1'), 'doc', 'info'], capture_output=True, text=True, timeout=30)
    assert result.returncode >= 0, f'Packaged executable crashed: {result.stderr}'
    assert 'could not load resource bundle' not in result.stderr
    assert 'Could not locate Handlers' not in result.stderr
    assert (root / 'docs/MCP_SETUP.md').is_file()
    print('PASS: archive checksum, resource bundle, relocated CLI/MCP, documentation')
