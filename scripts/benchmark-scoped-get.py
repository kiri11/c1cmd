#!/usr/bin/env python3
"""Compare separate scoped reads with one scoped get in the same persistent MCP process."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import statistics
import time

Client = runpy.run_path(str(Path(__file__).with_name('benchmark-reads.py')))['Client']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mcp', type=Path, default=Path('.build/release/c1-mcp'))
    parser.add_argument('--ref', required=True)
    parser.add_argument('--samples', type=int, default=5)
    parser.add_argument('--conditions', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.samples < 1:
        parser.error('samples must be positive')
    targets = [dict(scope=scope) for scope in ('adjustments', 'lens', 'variant')]
    binary = args.mcp.resolve()
    report = dict(version=1, conditions=args.conditions, ref=args.ref, targets=targets,
                  mcp=str(binary), mcpSHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  startedAt=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                  samples=[], completed=False)
    client = None
    with args.output.open('x') as output:
        try:
            client = Client(binary, dict(os.environ, C1_PROFILE='1'), 180)
            client.send('initialize', dict(protocolVersion='2024-11-05', capabilities={},
                        clientInfo=dict(name='c1-scoped-get-benchmark', version='1')))
            client.send('notifications/initialized', {}, notification=True)
            document = client.call('doc_info', {})
            report['document'] = document
            baseline = None
            for iteration in range(args.samples + 1):
                for mode in (['separate', 'batch'] if iteration % 2 == 0 else ['batch', 'separate']):
                    start = time.monotonic()
                    if mode == 'separate':
                        value = [client.call('get', dict(ref=args.ref, nativeTargets=[target]))['nativeSnapshots'][0] for target in targets]
                    else:
                        bundle = client.call('get', dict(ref=args.ref, nativeTargets=targets))
                        if bundle['openToken'] != document['openToken']:
                            raise RuntimeError('Document changed')
                        value = bundle['nativeSnapshots']
                    elapsed = (time.monotonic() - start) * 1000
                    if baseline is None:
                        baseline = value
                    if value != baseline:
                        raise RuntimeError('Native snapshots/tokens changed; results are not comparable')
                    report['samples'].append(dict(mode=mode, iteration=iteration, warmup=iteration == 0, elapsedMs=elapsed))
                    print(f'{mode} iteration {iteration}: {elapsed:.0f} ms', flush=True)
            if client.call('doc_info', {}) != document:
                raise RuntimeError('Document changed')
            report['snapshotSHA256'] = hashlib.sha256(json.dumps(baseline, sort_keys=True).encode()).hexdigest()
            report['summary'] = [dict(mode=mode, medianMs=statistics.median(
                row['elapsedMs'] for row in report['samples'] if row['mode'] == mode and not row['warmup']))
                for mode in ('separate', 'batch')]
            report['completed'] = True
        except BaseException as error:
            report['error'] = f'{type(error).__name__}: {error}'
            raise
        finally:
            if client:
                report['profiles'] = client.close()
            json.dump(report, output, indent=2)
            output.write('\n')
    print(json.dumps(report['summary'], indent=2))


if __name__ == '__main__':
    main()
