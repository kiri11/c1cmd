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

def extract_archive(archive, destination):
    archive = Path(archive).resolve()
    destination = Path(destination).resolve()
    expected = Path(str(archive) + '.sha256').read_text().split()[0]
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == expected
    with tarfile.open(archive) as tf:
        for member in tf.getmembers():
            assert not member.name.startswith('/') and '..' not in Path(member.name).parts
        tf.extractall(destination)
    root, = destination.iterdir()
    return root


def check_package(root):
    """Run every package/contract assertion on an already extracted archive."""
    binary = root / 'bin'
    script = binary / 'c1_CaptureOneCore.bundle' / 'Contents' / 'Resources' / 'Handlers.applescript'
    if not script.exists(): script = binary / 'c1_CaptureOneCore.bundle' / 'Handlers.applescript'
    assert script.is_file(), 'Missing runtime AppleScript resource'
    for name in ['NativeEditing.applescript','NativeActions.applescript','NativeEditing.json']:
        assert (script.parent / name).is_file(), 'Missing native editing resource: ' + name
    run(binary / 'c1', binary / 'c1-mcp')
    result = subprocess.run([str(binary / 'c1'), 'doc', 'info'], capture_output=True, text=True, timeout=30)
    assert result.returncode >= 0, f'Packaged executable crashed: {result.stderr}'
    assert 'could not load resource bundle' not in result.stderr
    assert 'Could not locate Handlers' not in result.stderr
    assert '## MCP setup' in (root / 'README.md').read_text()
    assert (root / 'docs/RELEASE_VALIDATION.md').is_file()
    assert (root / 'examples/crop-proposals.py').is_file()
    assert (root / 'examples/grade-folder.py').is_file()
    assert (root / 'examples/presets/daylight.json').is_file()
    print('PASS: archive checksum, resource bundle, relocated CLI/MCP, documentation')


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='c1-archive-') as tmp:
        root = extract_archive(sys.argv[1], tmp)
        os.chdir(tmp)
        check_package(root)
