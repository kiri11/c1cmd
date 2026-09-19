#!/usr/bin/env python3
"""Offline transport/contract regressions: no Capture One calls or RAW fixture required."""
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

class Client:
    def __init__(self, binary, env=None, timeout=15):
        self.process = subprocess.Popen([str(binary)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.id = 0
        self.timeout = timeout
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.request('initialize', {'protocolVersion': '2024-11-05', 'capabilities': {}, 'clientInfo': {'name': 'contract-test', 'version': '1'}})
        self.process.stdin.write(json.dumps({'jsonrpc': '2.0', 'method': 'notifications/initialized'}) + '\n')
        self.process.stdin.flush()
    def request(self, method, params):
        self.id += 1
        self.process.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': self.id, 'method': method, 'params': params}) + '\n')
        self.process.stdin.flush()
        assert self.selector.select(self.timeout), f'Timed out: {method}'
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


def assert_error_payload(value, schema, expected_code='invalid-request'):
    """Ensure additive error context remains represented by the shared schema."""
    validate_response(value, schema['definitions']['Error'])
    assert value['error']['code'] == expected_code, value


def run(cli, mcp):
    cli_schema = json.loads(subprocess.check_output([str(cli), 'schema'], text=True, timeout=15))
    client = Client(mcp)
    try:
        mcp_schema = json.loads(client.tool('schema')['content'][0]['text'])
        assert cli_schema == mcp_schema, 'CLI/MCP schema drift'
        tools = client.request('tools/list', {})['tools']
        assert len(tools) == 30
        assert "native_get" not in cli_schema["requests"]
        removed = client.tool('native_get', {'ref':'x', 'target':{'scope':'adjustments'}})
        assert removed.get('isError'), removed
        removed_cli = subprocess.run([str(cli), 'native', 'get', 'x'], capture_output=True, text=True, timeout=15)
        assert removed_cli.returncode != 0

        for tool in tools:
            assert tool['inputSchema'] == cli_schema['requests'][tool['name']]
        metadata_tool = next(t for t in tools if t['name'] == 'metadata_set')
        assert metadata_tool['annotations']['readOnlyHint'] is False
        assert metadata_tool['inputSchema']['properties']['colorTag']['maximum'] == 7
        for flag, value in [('rating', '-1'), ('rating', '6'), ('rating', '1.5'), ('color-tag', '-1'), ('color-tag', '8')]:
            result = subprocess.run([str(cli), 'metadata', 'set', 'x', '--if-metadata-state', 'h', '--' + flag, value], capture_output=True, text=True, timeout=15)
            assert result.returncode != 0 and 'applyMetadata' not in result.stderr
        rating_schema = cli_schema['requests']['variants_list']
        assert cli_schema['requests']['request_status'] == {
            'type': 'object', 'properties': {'requestId': {'type': 'string', 'minLength': 1}},
            'required': ['requestId'], 'additionalProperties': False,
        }
        request_status_tool = next(t for t in tools if t['name'] == 'request_status')
        assert request_status_tool['annotations']['readOnlyHint'] is True
        assert request_status_tool['annotations']['destructiveHint'] is False
        error_properties = cli_schema['definitions']['Error']['properties']['error']['properties']
        assert {'requestId', 'phase', 'elapsedMs', 'recoveryAction'} <= set(error_properties)
        assert error_properties['elapsedMs']['type'] == 'integer'
        for key in ['rating', 'minRating']:
            assert rating_schema['properties'][key]['type'] == 'integer'
            assert rating_schema['properties'][key]['minimum'] == 0
            assert rating_schema['properties'][key]['maximum'] == 5
        assert rating_schema['not'] == {'required': ['rating', 'minRating']}
        assert rating_schema['properties']['batchSize']['type'] == 'integer'
        assert rating_schema['properties']['batchSize']['minimum'] == 1
        assert rating_schema['properties']['batchSize']['maximum'] == 256
        assert rating_schema['properties']['deadlineSeconds']['type'] == 'number'
        assert rating_schema['properties']['deadlineSeconds']['exclusiveMinimum'] == 0
        assert rating_schema['properties']['deadlineSeconds']['maximum'] == 86400
        for name in ['preview', 'operation_status', 'variant_edit', 'geometry_restore']:
            assert next(t for t in tools if t['name'] == name)['annotations']['readOnlyHint'] is False
        assert next(t for t in tools if t['name'] == 'native_action')['annotations']['destructiveHint'] is True
        metadata_args = {'workingRef': 'x', 'ifMetadataState': 'h'}
        native_props = cli_schema['requests']['native_set']['properties']['patch']['properties']
        assert native_props['rgb curve']['items']['maximum'] == 100
        assert native_props['clarity amount']['type'] == 'number'
        assert native_props['enabled']['type'] == 'boolean'
        assert 'shift x' in native_props and 'range low' in native_props
        many_tool = next(t for t in tools if t['name'] == 'get')
        assert many_tool['annotations']['readOnlyHint'] is True
        assert many_tool['inputSchema']['properties']['nativeTargets']['maxItems'] == 16
        native_args = {'workingRef':'x','ifNativeState':'h','target':{'scope':'adjustments'}}
        for name, args in [
            *[('native_set', dict(native_args, patch=p)) for p in [None, 1, 'bad', [], {}, {'clarity amount':True}, {'rgb curve':[True,False]}, {'clarity amount':{}}, {'unknown':1}, {'flip':'horizontal'}]],
            *[('native_action', dict(native_args, action='layer.create', arguments=p)) for p in [None, 1, [], {}, {'name':'x','kind':'background'}]],
            *[('get', {'ref':'x','nativeTargets':targets}) for targets in
              [None, {}, [], [{'scope':'adjustments'}] * 17, [{'scope':'adjustments','layer':True}],
               [{'scope':'bad'}], [{'scope':'adjustments','unknown':1}], [{'scope':'lens','layer':1}]]],
            ('metadata_set', metadata_args),
            ('metadata_set', {'workingRef': 'x', 'rating': 5}),
            ('metadata_set', dict(metadata_args, unexpected=1, rating=5)),
            *[('metadata_set', dict(metadata_args, rating=value)) for value in [-1, 6, 1.5, True, '5', None]],
            *[('metadata_set', dict(metadata_args, colorTag=value)) for value in [-1, 8, 1.5, True, '4', None]],
            *[('variants_list', {key: value}) for key in ['rating', 'minRating']
              for value in [-1, 6, 4.5, True, '5', None]],
            ('variants_list', {'rating': 5, 'minRating': 4}),
            *[('variants_list', {'batchSize': value}) for value in [0, 257, -1, 1.5, True, '2', None]],
            *[('variants_list', {'deadlineSeconds': value}) for value in [0, -1, 86401, True, '2', None]],
            ('request_status', {}),
            ('request_status', {'requestId': ''}),
            ('request_status', {'requestId': 1}),
            ('request_status', {'requestId': 'req-00000000-0000-0000-0000-000000000000', 'extra': 1}),
            ('variant_edit', {'sourceRef':'1', 'ifGeometryState':'h'}),
            ('variant_edit', {'sourceRef':'1', 'ifGeometryState':'h', 'ifDocument':True}),
            ('geometry_restore', {'workingRef':'x'}),
            ('geometry_restore', {'workingRef':'x','ifGeometryState':'h','rotation':1}),
            ('geometry_set', {'workingRef':'x', 'ifGeometryState':'h'}),
            ('geometry_set', {'workingRef':'x', 'ifGeometryState':'h', 'rotation':46}),
            ('geometry_set', {'workingRef':'x', 'ifGeometryState':'h', 'rotation':True}),
            *[('geometry_set', {'workingRef':'x', 'ifGeometryState':'h', 'keystone':value})
              for value in [1, {}, {'unknown':1}, {'vertical':True}, {'horizontal':'1'}, {'skew':None},
                            {'amount':9}, {'amount':121}, {'amount':50.5}, {'vertical':76},
                            {'horizontal':-76}, {'skew':46}, {'aspect':-51}, {'aspect':101}]],
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
            assert_error_payload(json.loads(result['content'][0]['text']), cli_schema)
        for payload in ['{"exposure": 1, "unknown": 2}', '{"exposure": true}', '{"exposure": "bad", "contrast": 1}', '{}']:
            result = subprocess.run([str(cli), 'set', 'x', '--if-state', 'h', '--json', payload], capture_output=True, text=True, timeout=15)
            assert result.returncode != 0
            assert_error_payload(json.loads(result.stderr), cli_schema)
        for flag, value in [('amount', '9'), ('amount', '120.5'), ('vertical', '76'),
                            ('horizontal', '-76'), ('skew', 'nan'), ('aspect', '-51')]:
            result = subprocess.run([str(cli), 'geometry', 'set', 'x', '--if-geometry-state', 'h',
                                     f'--keystone-{flag}={value}', '--format', 'json'], capture_output=True, text=True, timeout=15)
            assert result.returncode != 0
            assert_error_payload(json.loads(result.stderr), cli_schema)
        for crop in ['1,2,bad,3,4', '1,2,,3,4', '1,2,3', '1,2,nan,4']:
            result = subprocess.run([str(cli), 'geometry', 'set', 'x', '--if-geometry-state', 'h', '--crop', crop, '--format', 'json'], capture_output=True, text=True, timeout=15)
            assert result.returncode != 0
            assert_error_payload(json.loads(result.stderr), cli_schema)
        for flags in [['--rating=-1'], ['--rating', '6'], ['--min-rating=-1'],
                      ['--min-rating', '6'], ['--rating', '5', '--min-rating', '4'],
                      ['--batch-size', '0'], ['--batch-size', '257'], ['--batch-size=-1'],
                      ['--deadline-seconds', '0'], ['--deadline-seconds=-1'], ['--deadline-seconds', '86401']]:
            result = subprocess.run([str(cli), 'variants', 'list', '--format', 'json', *flags], capture_output=True, text=True, timeout=15)
            assert result.returncode != 0
            assert_error_payload(json.loads(result.stderr), cli_schema)
        for key in ['--rating', '--min-rating']:
            for value in ['4.5', 'true', 'five']:
                result = subprocess.run([str(cli), 'variants', 'list', key, value], capture_output=True, text=True, timeout=15)
                assert result.returncode != 0 and f"is invalid for '{key}" in result.stderr, result.stderr
        assert not client.tool('capabilities').get('isError'), 'Server must survive malformed requests'
        print('PASS: shared CLI/MCP schemas, 30 tool schemas, invalid requests, server survival')
    finally:
        client.close()
    with tempfile.TemporaryDirectory(prefix='c1-contract-status-') as directory:
        env = dict(os.environ, C1_REQUEST_DIR=directory, C1_PROGRESS='quiet')
        local = Client(mcp, env=env)
        try:
            failure = json.loads(local.tool('variants_list', {'rating': 6})['content'][0]['text'])
            request_id = failure['error']['requestId']
            status = json.loads(local.tool('request_status', {'requestId': request_id})['content'][0]['text'])
            validate_response(status, cli_schema['responses']['request_status'])
            assert status['status'] == 'failed' and status['processAlive'] and not status['stale'], status
            command = subprocess.run([str(cli), 'request', 'status', request_id, '--format', 'json', '--quiet'],
                                     capture_output=True, text=True, env=env, timeout=15)
            assert command.returncode == 0 and not command.stderr, command.stderr
            assert json.loads(command.stdout)['requestId'] == request_id
            visible = subprocess.run([str(cli), 'version', '--format', 'json', '--progress', 'json'],
                                     capture_output=True, text=True, env=env, timeout=15)
            assert visible.returncode == 0 and json.loads(visible.stdout)['schemaVersion'] == cli_schema['version']
            events = [json.loads(line) for line in visible.stderr.splitlines()]
            assert events[0]['status'] == 'running' and events[-1]['status'] == 'completed', events
            assert all('requestId' in event for event in events)
            assert len(events) <= 4, 'Fast requests should not flood stderr'
            print('PASS: local request status, CLI quiet/JSON progress, stable stdout')
        finally:
            local.close()
    composition = Client(mcp, env=dict(os.environ, C1_MCP_PROFILE='composition'))
    try:
        names = {t['name'] for t in composition.request('tools/list', {})['tools']}
        assert {'geometry_set','variant_edit','geometry_restore'} <= names
        assert 'variants_list' in names
        result = composition.tool('variants_list', {'rating': 6})
        assert result['isError']; assert_error_payload(json.loads(result['content'][0]['text']), cli_schema)
        assert not names.intersection({'set','add','reset','variant_baseline','metadata_set','native_set','native_action'})
        result = composition.tool('set', {'workingRef':'x','ifState':'h','exposure':1})
        assert result['isError'] and 'not enabled' in result['content'][0]['text']
        result = composition.tool('metadata_set', {'workingRef':'x','ifMetadataState':'h','rating':5})
        assert result['isError'] and 'not enabled' in result['content'][0]['text']
        print('PASS: composition profile hides and rejects tonal and metadata mutation tools')
    finally:
        composition.close()

if __name__ == '__main__':
    run(Path(os.environ.get('C1_TEST_BIN', ROOT / '.build/debug/c1')),
        Path(os.environ.get('C1_TEST_MCP_BIN', ROOT / '.build/debug/c1-mcp')))
