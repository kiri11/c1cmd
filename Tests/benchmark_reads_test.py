#!/usr/bin/env python3
"""Offline protocol/evidence tests; no Capture One access."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE = '''#!/usr/bin/env python3
import json, os, sys
value = {"stateHash": "stable"}
if len(sys.argv) > 1:
    print(json.dumps(value))
else:
    for line in sys.stdin:
        req = json.loads(line)
        if "id" not in req: continue
        if req["method"] == "initialize": result = {}
        else:
            name = req["params"]["name"]
            payload = {"openToken":"document"} if name == "doc_info" else value
            if os.environ.get("BENCHMARK_DRIFT") and name == "get": payload = {"stateHash":"changed"}
            result = {"content":[{"type":"text","text":json.dumps(payload)}]}
        print(json.dumps({"jsonrpc":"2.0","id":req["id"],"result":result}),flush=True)
'''


class BenchmarkTests(unittest.TestCase):
    def run_fixture(self, drift=False):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            fake = base / 'fake'
            fake.write_text(FAKE)
            fake.chmod(0o755)
            output = base / 'result.json'
            command = ['python3', str(ROOT/'scripts/benchmark-reads.py'), '--cli', str(fake),
                       '--mcp', str(fake), '--ref', '1', '--samples', '2', '--timeout', '5',
                       '--conditions', 'offline fake', '--output', str(output)]
            env = dict(os.environ)
            if drift:
                env['BENCHMARK_DRIFT'] = '1'
            run = subprocess.run(command, capture_output=True, text=True, env=env, timeout=20)
            report = json.loads(output.read_text())
            original = output.read_bytes()
            repeat = subprocess.run(command, capture_output=True, text=True, env=env, timeout=20)
            self.assertNotEqual(repeat.returncode, 0)
            self.assertEqual(output.read_bytes(), original)
            return run, report

    def test_stable_samples_and_warmup(self):
        run, report = self.run_fixture()
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue(report['completed'])
        self.assertEqual(len(report['samples']), 12)
        self.assertEqual(sum(row['warmup'] for row in report['samples']), 4)
        self.assertEqual(len(report['summary']), 4)

    def test_drift_stops_and_preserves_partial_evidence(self):
        run, report = self.run_fixture(drift=True)
        self.assertNotEqual(run.returncode, 0)
        self.assertFalse(report['completed'])
        self.assertIn('changed during benchmark', report['error'])
        self.assertEqual(len(report['samples']), 1)
        self.assertNotIn('summary', report)


if __name__ == '__main__':
    unittest.main()
