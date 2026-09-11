#!/usr/bin/env python3
"""Offline transport/contract regressions: no Capture One calls or RAW fixture required."""
import json
import os
from pathlib import Path
import selectors
import subprocess

ROOT = Path(__file__).resolve().parents[1]

class Client:
    def __init__(self, binary, env=None):
        self.process = subprocess.Popen([str(binary)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.id = 0
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.request('initialize', {'protocolVersion': '2024-11-05', 'capabilities': {}, 'clientInfo': {'name': 'contract-test', 'version': '1'}})
        self.process.stdin.write(json.dumps({'jsonrpc': '2.0', 'method': 'notifications/initialized'}) + '\n')
        self.process.stdin.flush()
    def request(self, method, params):
        self.id += 1
        self.process.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': self.id, 'method': method, 'params': params}) + '\n')
        self.process.stdin.flush()
        assert self.selector.select(15), f'Timed out: {method}'
        response = json.loads(self.process.stdout.readline())
        assert response.get('id') == self.id, response
        assert 'error' not in response, response
        return response['result']
    def tool(self, name, args=None):
        return self.request('tools/call', {'name': name, 'arguments': args or {}})
    def close(self):
        self.process.terminate()
        try: self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill(); self.process.wait()
        self.selector.close()


def validate_response(value, schema, path='response'):
    """Small validator for the emitted response schema vocabulary; no third-party runtime."""
    kind = schema.get('type')
    allowed = kind if isinstance(kind, list) else [kind]
    checks = {'object': lambda x: isinstance(x, dict), 'array': lambda x: isinstance(x, list),
              'string': lambda x: isinstance(x, str), 'number': lambda x: isinstance(x, (int, float)) and not isinstance(x, bool),
              'integer': lambda x: isinstance(x, int) and not isinstance(x, bool), 'boolean': lambda x: isinstance(x, bool),
              'null': lambda x: x is None}
    if kind is not None:
        assert any(checks[k](value) for k in allowed), (path, kind, value)
    if 'enum' in schema: assert value in schema['enum'], (path, value)
    if isinstance(value, dict):
        assert all(k in value for k in schema.get('required', [])), (path, 'missing required keys')
        assert len(value) >= schema.get('minProperties', 0), path
        props = schema.get('properties', {})
        for key, item in value.items():
            if key in props: validate_response(item, props[key], path + '.' + key)
            elif schema.get('additionalProperties') is False: raise AssertionError((path, 'unknown field', key))
            elif isinstance(schema.get('additionalProperties'), dict): validate_response(item, schema['additionalProperties'], path + '.' + key)
    if isinstance(value, list) and 'items' in schema:
        for item in value: validate_response(item, schema['items'], path + '[]')
    if isinstance(value, str): assert len(value) >= schema.get('minLength', 0), path


def run(cli, mcp):
    cli_schema = json.loads(subprocess.check_output([str(cli), 'schema'], text=True, timeout=15))
    client = Client(mcp)
    try:
        mcp_schema = json.loads(client.tool('schema')['content'][0]['text'])
        assert cli_schema == mcp_schema, 'CLI/MCP schema drift'
        tools = client.request('tools/list', {})['tools']
        assert len(tools) == 17
        for tool in tools:
            assert tool['inputSchema'] == cli_schema['requests'][tool['name']]
        for name in ['preview', 'operation_status']:
            assert next(t for t in tools if t['name'] == name)['annotations']['readOnlyHint'] is False
        for name, args in [
            ('geometry_set', {'workingRef':'x', 'ifGeometryState':'h'}),
            ('geometry_set', {'workingRef':'x', 'ifGeometryState':'h', 'rotation':46}),
            ('geometry_set', {'workingRef':'x', 'ifGeometryState':'h', 'rotation':True}),
            ('geometry_set', {'workingRef':'x', 'ifGeometryState':'h', 'keystone':1}),
            ('geometry_set', {'workingRef':'x', 'ifGeometryState':'h', 'aspectRatio':0}),
            ('geometry_set', {'workingRef':'x', 'ifGeometryState':'h', 'crop':{'width':3}}),
            ('geometry_set', {'workingRef':'x', 'ifGeometryState':'h', 'crop':{'centerX':10,'centerY':10,'width':3,'height':2},'aspectRatio':1.5}),
            ('preview', {'ref':'x','fullFrame':'yes'}),
            ('reset', {'workingRef': 'x', 'ifState': 'h', 'fields': [123]}),
            ('reset', {'workingRef': 'x', 'ifState': 'h', 'fields': 'exposure'}),
            ('set', {'workingRef': 'x', 'ifState': 'h', 'exposure': 'oops', 'contrast': 1}),
            ('set', {'workingRef': 'x', 'ifState': 'h', 'exposure': True}),
            ('set', {'workingRef': 'x', 'ifState': 'h', 'exp': 1, 'exposure': 2}),
            ('set', {'workingRef': 'x', 'ifState': 'h', 'adjustments': {}, 'exposure': 1}),
            ('dump', {'batchSize': -1}), ('dump', {'batchSize': 0}), ('dump', {'batchSize': 1001}),
            ('dump', {'batchSize': 1.5}), ('preview', {'ref': '1', 'timeout': -1}),
            ('preview', {'ref': '1', 'timeout': 301}), ('get', {'ref': 1}),
        ]:
            result = client.tool(name, args)
            assert result.get('isError'), (name, args, result)
            assert json.loads(result['content'][0]['text'])['error']['code'] == 'invalid-request', result
        for payload in ['{"exposure": 1, "unknown": 2}', '{"exposure": true}', '{"exposure": "bad", "contrast": 1}', '{}']:
            result = subprocess.run([str(cli), 'set', 'x', '--if-state', 'h', '--json', payload], capture_output=True, text=True, timeout=15)
            assert result.returncode != 0
            assert json.loads(result.stderr)['error']['code'] == 'invalid-request', result.stderr
        for crop in ['1,2,bad,3,4', '1,2,,3,4', '1,2,3', '1,2,nan,4']:
            result = subprocess.run([str(cli), 'geometry', 'set', 'x', '--if-geometry-state', 'h', '--crop', crop, '--format', 'json'], capture_output=True, text=True, timeout=15)
            assert result.returncode != 0
            assert json.loads(result.stderr)['error']['code'] == 'invalid-request', result.stderr
        assert not client.tool('capabilities').get('isError'), 'Server must survive malformed requests'
        print('PASS: shared CLI/MCP schemas, 17 tool schemas, invalid requests, server survival')
    finally:
        client.close()
    composition = Client(mcp, env=dict(os.environ, C1_MCP_PROFILE='composition'))
    try:
        names = {t['name'] for t in composition.request('tools/list', {})['tools']}
        assert 'geometry_set' in names
        assert not names.intersection({'set','add','reset','variant_baseline'})
        result = composition.tool('set', {'workingRef':'x','ifState':'h','exposure':1})
        assert result['isError'] and 'not enabled' in result['content'][0]['text']
        print('PASS: composition profile hides and rejects tonal mutation tools')
    finally:
        composition.close()

if __name__ == '__main__':
    run(Path(os.environ.get('C1_TEST_BIN', ROOT / '.build/debug/c1')),
        Path(os.environ.get('C1_TEST_MCP_BIN', ROOT / '.build/debug/c1-mcp')))
