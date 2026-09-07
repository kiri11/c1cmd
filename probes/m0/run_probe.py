#!/usr/bin/env python3
"""Run a retained AppleScript probe and append exact output to a JSONL log.

Usage: python3 probes/m0/run_probe.py PROBE.applescript [arguments ...]
Run only against disposable Sessions. Scripts that change application-wide state
must retain and conditionally restore it. This runner does not retry failures.
"""
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[2]
script = Path(sys.argv[1]).resolve()
started = time.perf_counter()
result = subprocess.run(["/usr/bin/osascript", "-s", "s", str(script), *sys.argv[2:]],
                        capture_output=True, text=True)
entry = {"utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
         "script": str(script.relative_to(root)),
         "sha256": hashlib.sha256(script.read_bytes()).hexdigest(),
         "args": sys.argv[2:], "seconds": time.perf_counter() - started,
         "returncode": result.returncode, "stdout": result.stdout,
         "stderr": result.stderr}
with (root / "docs/m0/16.8.5.30/runtime.jsonl").open("a") as output:
    output.write(json.dumps(entry) + "\n")
print(json.dumps(entry, indent=2))
sys.exit(result.returncode)
