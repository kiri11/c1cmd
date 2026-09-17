#!/usr/bin/env python3
"""Offline failure-path checks; never launches or contacts Capture One."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

path = Path(__file__).with_name('recovery_diagnostic_probe.py').resolve()
spec = importlib.util.spec_from_file_location('probe', path)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
for scenario in ['quit-reply-timeout', 'process-exit-timeout', 'sample-failure', 'reopen-failure']:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        raw = root / 'source.CR3'
        raw.write_bytes(b'offline fixture')
        binary = root / 'c1'
        binary.write_bytes(b'offline binary')
        parent = root / 'fixtures'
        evidence = root / 'evidence'
        state = {'closed': False, 'shutdownStarted': False}
        events = []
        def ae(body, timeout=20):
            events.append(body)
            assert not state['shutdownStarted'], 'Unexpected application call after incomplete restart'
            if body == 'return count of documents': return 0
            if body == 'return version': return '16.8.5.30'
            if body == 'return id of first document': return str(next(parent.iterdir()) / 'diagnostic')
            if body == 'close first document': state['closed'] = True
            if body == 'quit':
                state['shutdownStarted'] = True
                if scenario in ['quit-reply-timeout', 'sample-failure']:
                    raise subprocess.TimeoutExpired('osascript', timeout)
        def run(args, **kwargs):
            if args[0] == 'sample':
                if scenario == 'sample-failure': raise OSError('sample unavailable')
                return subprocess.CompletedProcess(args, 0)
            if args[0] == 'open': raise subprocess.CalledProcessError(1, args)
            assert Path(args[0]).resolve() == binary.resolve()
            command = args[1]
            result = {'doctor': {'allChecksPassed': True, 'writesEnabled': True, 'exactBuildMatched': True, 'appVersion': '16.8.5.30'},
                      'variants': [{'id': '1', 'parentImagePath': str(raw)}],
                      'variant': {'workingRef': 'c1_wrk_test'},
                      'get': {'stateHash': 'state', 'adjustments': {'exposure': 0}}, 'set': {}}[command]
            return subprocess.CompletedProcess(args, 0, json.dumps(result), '')
        def wait(predicate, seconds=30):
            if seconds == 15:
                if scenario == 'process-exit-timeout': raise TimeoutError('process still alive')
                return True
            return predicate()
        with patch.dict(os.environ, C1_TEST_RAW_FIXTURE=str(raw), C1_TEST_BIN=str(binary)), \
             patch.object(sys, 'argv', [str(path), '--parent', str(parent), '--evidence', str(evidence), '--cycles', '1']), \
             patch.object(probe, 'ae', ae), patch.object(probe, 'app_pid', return_value=123), \
             patch.object(probe, 'wait_for', wait), patch.object(probe.subprocess, 'run', run), \
             patch.object(probe, 'database_snapshot', return_value={'images': [], 'paths': [], 'variants': []}), \
             patch.object(probe.os, 'kill') as signal:
            try: probe.main()
            except (subprocess.TimeoutExpired, TimeoutError, subprocess.CalledProcessError): pass
            else: raise AssertionError('Failure must propagate')
            signal.assert_not_called()
        records = [json.loads(line) for line in (evidence / 'events.jsonl').read_text().splitlines()]
        names = [r['event'] for r in records]
        assert names[-1] == 'failed'
        assert 'cleanup' not in names
        assert ('quit-stalled' in names) == (scenario != 'reopen-failure')
        assert ('sample-failed' in names) == (scenario == 'sample-failure')
        assert events[-1] == 'quit'
        print('PASS', scenario)
compile(path.read_text(), str(path), 'exec')
print('PASS syntax; 4 failure paths retain evidence without retry, fallback, or cleanup Apple Events')
