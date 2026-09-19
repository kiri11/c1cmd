#!/usr/bin/env python3
"""Sequential, read-only CLI versus persistent MCP benchmark. Never exports or edits."""
import argparse
import json
import os
from pathlib import Path
import queue
import statistics
import subprocess
import tempfile
import threading
import time


def profile_records(text):
    records = []
    for line in text.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and row.get('type') == 'c1-profile':
            records.append(row)
    return records


class Client:
    def __init__(self, binary, env, timeout):
        self.stderr = tempfile.TemporaryFile(mode='w+')
        self.proc = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=self.stderr, text=True, env=env)
        self.timeout = timeout
        self.responses = queue.Queue()
        self.seq = 0
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            self.responses.put(line)
        self.responses.put(None)

    def send(self, method, params, notification=False):
        self.seq += 1
        message = dict(jsonrpc='2.0', method=method, params=params)
        if not notification:
            message['id'] = self.seq
        self.proc.stdin.write(json.dumps(message) + '\n')
        self.proc.stdin.flush()
        if notification:
            return
        deadline = time.monotonic() + self.timeout
        while True:
            line = self.responses.get(timeout=max(0, deadline - time.monotonic()))
            if line is None:
                raise RuntimeError('MCP closed stdout')
            response = json.loads(line)
            if response.get('id') != self.seq:
                continue
            if 'error' in response:
                raise RuntimeError(response['error'])
            return response['result']

    def call(self, name, args):
        result = self.send('tools/call', dict(name=name, arguments=args))
        if result.get('isError'):
            raise RuntimeError(result)
        return json.loads('\n'.join(x['text'] for x in result['content'] if x['type'] == 'text'))

    def close(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.proc.stdout.close()
        self.stderr.seek(0)
        records = profile_records(self.stderr.read())
        self.stderr.close()
        return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, default=Path('.build/debug/c1'))
    parser.add_argument('--mcp', type=Path, default=Path('.build/debug/c1-mcp'))
    parser.add_argument('--ref', required=True, help='Native variant ID in the single open document')
    parser.add_argument('--samples', type=int, default=5, help='Measured pairs after one warmup pair')
    parser.add_argument('--timeout', type=float, default=120)
    parser.add_argument('--conditions', required=True, help='Record screen lock, app load, fixture and build conditions')
    parser.add_argument('--output', type=Path, required=True, help='New evidence file; never overwrite')
    args = parser.parse_args()
    if args.samples < 1 or args.timeout <= 0:
        parser.error('samples and timeout must be positive')
    env = dict(os.environ, C1_PROFILE='1')
    report = dict(version=1, conditions=args.conditions, ref=args.ref,
                  cli=str(args.cli.resolve()), mcp=str(args.mcp.resolve()),
                  startedAt=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                  samples=[], profiles=[], completed=False)
    # Reserve the output before starting any native reads and save partial failures.
    with args.output.open('x') as output:
        client = None
        try:
            client = Client(args.mcp.resolve(), env, args.timeout)
            client.send('initialize', dict(protocolVersion='2024-11-05', capabilities={},
                        clientInfo=dict(name='c1-read-benchmark', version='1')))
            client.send('notifications/initialized', {}, notification=True)
            document = client.call('doc_info', {})
            report['document'] = document
            baseline = {}
            commands = [('get', ['get', args.ref], {'ref': args.ref}),
                        ('native_get', ['native', 'get', args.ref, '--scope', 'adjustments'],
                         {'ref': args.ref, 'target': {'scope': 'adjustments'}})]
            for iteration in range(args.samples + 1):
                # Alternate order to reduce systematic warm-cache/application-load bias.
                modes = ['cli', 'mcp'] if iteration % 2 == 0 else ['mcp', 'cli']
                for name, command, arguments in commands:
                    for mode in modes:
                        start = time.monotonic()
                        if mode == 'cli':
                            result = subprocess.run([str(args.cli.resolve()), *command], env=env,
                                                    capture_output=True, text=True, timeout=args.timeout)
                            report['profiles'].extend(profile_records(result.stderr))
                            if result.returncode:
                                raise RuntimeError(result.stdout + result.stderr)
                            value = json.loads(result.stdout)
                        else:
                            value = client.call(name, arguments)
                        elapsed = (time.monotonic() - start) * 1000
                        if name not in baseline:
                            baseline[name] = value
                        if value != baseline[name]:
                            raise RuntimeError(f'{name} changed during benchmark; timings are not comparable')
                        report['samples'].append(dict(mode=mode, operation=name, iteration=iteration,
                                                      warmup=iteration == 0, elapsedMs=elapsed))
            if client.call('doc_info', {}) != document:
                raise RuntimeError('Document changed during benchmark')
            report['summary'] = [dict(mode=mode, operation=name, medianMs=statistics.median(
                x['elapsedMs'] for x in report['samples']
                if x['mode'] == mode and x['operation'] == name and not x['warmup']))
                for mode in ('cli', 'mcp') for name, _, _ in commands]
            report['completed'] = True
        except BaseException as error:
            report['error'] = f'{type(error).__name__}: {error}'
            raise
        finally:
            if client:
                report['profiles'].extend(client.close())
            json.dump(report, output, indent=2)
            output.write('\n')
    print(json.dumps(report['summary'], indent=2))


if __name__ == '__main__':
    main()
