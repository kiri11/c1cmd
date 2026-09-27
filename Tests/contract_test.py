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
        assert len(tools) == 35
        assert "native_get" not in cli_schema["requests"]
        removed = client.tool('native_get', {'ref':'x', 'target':{'scope':'adjustments'}})
        assert removed.get('isError'), removed
        removed_cli = subprocess.run([str(cli), 'native', 'get', 'x'], capture_output=True, text=True, timeout=15)
        assert removed_cli.returncode != 0

        for tool in tools:
            assert tool['inputSchema'] == cli_schema['requests'][tool['name']]
        for args in [{"ids": []}, {"ids": ["1", "1"]}, {"ids": [str(i) for i in range(513)]},
                     {"ids": ["1"], "fields": "unknown"}, {"fields": "minimal"}, {"parentPath": "/a.CR3"}]:
            assert client.tool("variants_list", args).get("isError"), args
        for flags in [["--ids", "1,1"], ["--ids", "1", "--fields", "unknown"], ["--fields", "minimal"]]:
            result = subprocess.run([str(cli), "variants", "list", *flags], capture_output=True, text=True, timeout=15)
            assert result.returncode != 0 and "invalid-request" in result.stderr, result.stderr
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
        assert rating_schema['properties']['ids']['maxItems'] == 512
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
        bad_recipe = dict(version=1, referenceId='a'*64, settings={'clarity amount':5},
                          exposure={'mode':'magic'}, whiteBalance={'mode':'preserve'}, cropPolicy='preserve')
        for name, args in [('recipe_register', {'recipe':bad_recipe}),
                           ('reference_capture', {'ref':'1'}),
                           ('edit_status', {'compoundId':'../escape'}),
                           ('edit_apply', {'recipeId':'a'*64,'sourceRef':'1','ifState':'s','ifDocument':'d',
                                           'geometry':{'rotation':1}})]:
            result = client.tool(name,args)
            assert result.get('isError'), result
            assert_error_payload(json.loads(result['content'][0]['text']),cli_schema)
        with tempfile.TemporaryDirectory() as directory:
            request = Path(directory)/'invalid-recipe.json'
            request.write_text(json.dumps({'recipe':bad_recipe}))
            result = subprocess.run([str(cli),'recipe','register','--file',str(request),'--format','json'],capture_output=True,text=True,timeout=15)
            assert result.returncode != 0
            assert_error_payload(json.loads(result.stderr),cli_schema)
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
        print('PASS: shared CLI/MCP schemas, 35 tool schemas, invalid requests, server survival')
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

# Each case: tool, CLI arguments, MCP arguments. Accepted cases name the arguments
# object the CLI flags must produce; rejected cases must fail identically.
RECIPE = dict(version=1, referenceId='a' * 64, settings={'clarity amount': 5},
              exposure={'mode': 'preserve'}, whiteBalance={'mode': 'preserve'}, cropPolicy='preserve')
HEX = 'b' * 64
ACCEPTED = [
    ('doctor', ['doctor'], {}),
    ('doc_info', ['doc', 'info'], {}),
    ('capabilities', ['capabilities'], {}),
    ('schema', ['schema'], {}),
    ('read_session_begin', ['read-session', 'begin', '--collection', 'Capture', '--selected'], {'collection': 'Capture', 'selected': True}),
    ('read_session_end', ['read-session', 'end', '--read-workflow', 'w1'], {'readWorkflow': 'w1'}),
    ('read_session_status', ['read-session', 'status', '--read-workflow', 'w1'], {'readWorkflow': 'w1'}),
    ('catalog_get', ['get', '7', '--database', '/x/c.cocatalogdb'], {'database': '/x/c.cocatalogdb', 'variantID': 7}),
    ('catalog_variants', ['catalog', 'variants', '--database', '/x/c.cocatalogdb', '--collection-id', '3', '--min-rating', '2'],
     {'database': '/x/c.cocatalogdb', 'collectionID': 3, 'minRating': 2}),
    ('catalog_variants', ['variants', 'list', '--database', '/x/c.cocatalogdb', '--rating', '5'], {'database': '/x/c.cocatalogdb', 'rating': 5}),
    ('catalog_inspect', ['catalog', 'inspect', '--database', '/x/c.cocatalogdb'], {'database': '/x/c.cocatalogdb'}),
    ('catalog_snapshot', ['catalog', 'snapshot', '--database', '/x/c.cocatalogdb', '--destination', '/x/s.db'],
     {'database': '/x/c.cocatalogdb', 'destination': '/x/s.db'}),
    ('native_set', ['native', 'set', 'x', '--if-native-state', 'h', '--json', '{"clarity amount": 5}', '--dry-run'],
     {'workingRef': 'x', 'ifNativeState': 'h', 'target': {'scope': 'adjustments'}, 'patch': {'clarity amount': 5}, 'dryRun': True}),
    ('native_action', ['native', 'action', 'x', 'layer.create', '--if-native-state', 'h', '--json', '{"name": "L", "kind": "adjustment"}'],
     {'workingRef': 'x', 'ifNativeState': 'h', 'target': {'scope': 'adjustments'}, 'action': 'layer.create', 'arguments': {'name': 'L', 'kind': 'adjustment'}}),
    ('native_action', ['native', 'action', 'x', 'mask.clear', '--if-native-state', 'h', '--scope', 'layer', '--layer', '2'],
     {'workingRef': 'x', 'ifNativeState': 'h', 'target': {'scope': 'layer', 'layer': 2}, 'action': 'mask.clear'}),
    ('variants_list', ['variants', 'list', '--rating', '5', '--batch-size', '64', '--selected', '--collection', 'C', '--deadline-seconds', '9'],
     {'rating': 5, 'batchSize': 64, 'selected': True, 'collection': 'C', 'deadlineSeconds': 9}),
    ('variants_list', ['variants', 'list', '--ids', '1,2', '--fields', 'summary', '--parent-path', '/a.CR3', '--live', '--read-workflow', 'w1'],
     {'ids': ['1', '2'], 'fields': 'summary', 'parentPath': '/a.CR3', 'live': True, 'readWorkflow': 'w1'}),
    ('variant_edit', ['variant', 'edit', '1', '--if-state', 's', '--if-document', 'd', '--if-geometry-state', 'g'],
     {'sourceRef': '1', 'ifState': 's', 'ifDocument': 'd', 'ifGeometryState': 'g'}),
    ('variant_clone', ['variant', 'clone', '1'], {'sourceRef': '1'}),
    ('variant_delete', ['variant', 'delete', 'c1_wrk_x'], {'workingRef': 'c1_wrk_x'}),
    ('variant_baseline', ['variant', 'baseline', '1'], {'sourceRef': '1'}),
    ('get', ['get', '1', '--live', '--native-targets', '[{"scope": "lens"}]'], {'ref': '1', 'live': True, 'nativeTargets': [{'scope': 'lens'}]}),
    ('metadata_set', ['metadata', 'set', 'x', '--if-metadata-state', 'h', '--rating', '5', '--color-tag', '0', '--dry-run'],
     {'workingRef': 'x', 'ifMetadataState': 'h', 'rating': 5, 'colorTag': 0, 'dryRun': True}),
    ('set', ['set', 'x', '--if-state', 'h', 'exposure=0.5', 'kelvin=5400'], {'workingRef': 'x', 'ifState': 'h', 'adjustments': {'exposure': 0.5, 'kelvin': 5400}}),
    ('add', ['add', 'x', '--if-state', 'h', '--json', '{"exp": -0.25}', '--dry-run'], {'workingRef': 'x', 'ifState': 'h', 'adjustments': {'exp': -0.25}, 'dryRun': True}),
    ('geometry_set', ['geometry', 'set', 'x', '--if-geometry-state', 'h', '--crop', '10,20,30,40', '--rotation', '1.5', '--keystone-vertical', '10'],
     {'workingRef': 'x', 'ifGeometryState': 'h', 'crop': {'centerX': 10, 'centerY': 20, 'width': 30, 'height': 40}, 'rotation': 1.5, 'keystone': {'vertical': 10}}),
    ('geometry_set', ['geometry', 'set', 'x', '--if-geometry-state', 'h', '--aspect-ratio', '1.5', '--dry-run'],
     {'workingRef': 'x', 'ifGeometryState': 'h', 'aspectRatio': 1.5, 'dryRun': True}),
    ('geometry_restore', ['geometry', 'restore', 'x', '--if-geometry-state', 'h', '--dry-run'], {'workingRef': 'x', 'ifGeometryState': 'h', 'dryRun': True}),
    ('reset', ['reset', 'x', '--if-state', 'h', 'exposure', 'contrast'], {'workingRef': 'x', 'ifState': 'h', 'fields': ['exposure', 'contrast']}),
    ('diff', ['diff', 'a', 'b', '--live'], {'ref1': 'a', 'ref2': 'b', 'live': True}),
    ('dump', ['dump', '--collection', 'C', '--batch-size', '50', '--selected'], {'collection': 'C', 'batchSize': 50, 'selected': True}),
    ('preview', ['preview', 'x', '--timeout', '60', '--full-frame', '--output-dir', '/x/o'], {'ref': 'x', 'timeout': 60, 'fullFrame': True, 'outputDir': '/x/o'}),
    ('operation_status', ['operation', 'status', 'op1'], {'operationId': 'op1'}),
    ('request_status', ['request', 'status', 'req-1'], {'requestId': 'req-1'}),
    ('reference_capture', ['recipe', 'capture'], {'ref': '1', 'ifDocument': 'd', 'ifState': 's'}),
    ('recipe_register', ['recipe', 'register'], {'recipe': RECIPE}),
    ('recipe_verify', ['recipe', 'verify'], {'recipeId': HEX, 'workingRef': 'x', 'ifDocument': 'd', 'ifState': 's'}),
    ('edit_apply', ['recipe', 'apply'], {'recipeId': HEX, 'sourceRef': '1', 'ifDocument': 'd', 'ifState': 's'}),
    ('edit_status', ['recipe', 'status'], {'compoundId': HEX}),
]
REJECTED = [
    ('read_session_begin', ['read-session', 'begin', '--collection', ''], {'collection': ''}),
    ('read_session_end', ['read-session', 'end'], {}),
    ('read_session_status', ['read-session', 'status'], {}),
    ('catalog_get', ['get', '7', '--database', ' '], {'database': ' ', 'variantID': 7}),
    ('catalog_variants', ['catalog', 'variants', '--database', 'd', '--rating', '6'], {'database': 'd', 'rating': 6}),
    ('catalog_inspect', ['catalog', 'inspect', '--database', ''], {'database': ''}),
    ('catalog_snapshot', ['catalog', 'snapshot', '--database', 'd', '--destination', ''], {'database': 'd', 'destination': ''}),
    ('native_set', ['native', 'set', 'x', '--if-native-state', 'h', '--json', '{"unknown": 1}'],
     {'workingRef': 'x', 'ifNativeState': 'h', 'target': {'scope': 'adjustments'}, 'patch': {'unknown': 1}}),
    ('native_action', ['native', 'action', 'x', 'layer.create', '--if-native-state', 'h', '--json', '{"name": "L", "kind": "background"}'],
     {'workingRef': 'x', 'ifNativeState': 'h', 'target': {'scope': 'adjustments'}, 'action': 'layer.create', 'arguments': {'name': 'L', 'kind': 'background'}}),
    ('variants_list', ['variants', 'list', '--rating', '5', '--min-rating', '4'], {'rating': 5, 'minRating': 4}),
    ('variants_list', ['variants', 'list', '--ids', '1,1'], {'ids': ['1', '1']}),
    ('variants_list', ['variants', 'list', '--batch-size', '257'], {'batchSize': 257}),
    ('variant_edit', ['variant', 'edit', '1', '--if-state', '', '--if-document', 'd'], {'sourceRef': '1', 'ifState': '', 'ifDocument': 'd'}),
    ('variant_clone', ['variant', 'clone', ''], {'sourceRef': ''}),
    ('variant_delete', ['variant', 'delete', ' '], {'workingRef': ' '}),
    ('variant_baseline', ['variant', 'baseline', ''], {'sourceRef': ''}),
    ('get', ['get', '1', '--native-targets', '[]'], {'ref': '1', 'nativeTargets': []}),
    ('metadata_set', ['metadata', 'set', 'x', '--if-metadata-state', 'h', '--rating', '6'], {'workingRef': 'x', 'ifMetadataState': 'h', 'rating': 6}),
    ('metadata_set', ['metadata', 'set', 'x', '--if-metadata-state', 'h', '--color-tag', '8'], {'workingRef': 'x', 'ifMetadataState': 'h', 'colorTag': 8}),
    ('metadata_set', ['metadata', 'set', 'x', '--if-metadata-state', 'h'], {'workingRef': 'x', 'ifMetadataState': 'h'}),
    ('set', ['set', 'x', '--if-state', 'h', 'exposure=9'], {'workingRef': 'x', 'ifState': 'h', 'adjustments': {'exposure': 9}}),
    ('set', ['set', 'x', '--if-state', 'h', 'bogus=1'], {'workingRef': 'x', 'ifState': 'h', 'adjustments': {'bogus': 1}}),
    ('add', ['add', 'x', '--if-state', 'h', 'exp=1', 'exposure=2'], {'workingRef': 'x', 'ifState': 'h', 'adjustments': {'exp': 1, 'exposure': 2}}),
    ('geometry_set', ['geometry', 'set', 'x', '--if-geometry-state', 'h', '--rotation', '46'], {'workingRef': 'x', 'ifGeometryState': 'h', 'rotation': 46}),
    ('geometry_set', ['geometry', 'set', 'x', '--if-geometry-state', 'h'], {'workingRef': 'x', 'ifGeometryState': 'h'}),
    ('geometry_set', ['geometry', 'set', 'x', '--if-geometry-state', 'h', '--keystone-amount', '9'],
     {'workingRef': 'x', 'ifGeometryState': 'h', 'keystone': {'amount': 9}}),
    ('geometry_restore', ['geometry', 'restore', 'x', '--if-geometry-state', ''], {'workingRef': 'x', 'ifGeometryState': ''}),
    ('reset', ['reset', 'x', '--if-state', 'h', 'bogus'], {'workingRef': 'x', 'ifState': 'h', 'fields': ['bogus']}),
    ('diff', ['diff', ''], {'ref1': ''}),
    ('dump', ['dump', '--batch-size', '0'], {'batchSize': 0}),
    ('preview', ['preview', 'x', '--timeout', '301'], {'ref': 'x', 'timeout': 301}),
    ('operation_status', ['operation', 'status', ''], {'operationId': ''}),
    ('request_status', ['request', 'status', ''], {'requestId': ''}),
    ('reference_capture', ['recipe', 'capture'], {'ref': '1'}),
    ('recipe_register', ['recipe', 'register'], {'recipe': dict(RECIPE, exposure={'mode': 'magic'})}),
    ('recipe_verify', ['recipe', 'verify'], {'recipeId': 'short', 'workingRef': 'x', 'ifDocument': 'd', 'ifState': 's'}),
    ('edit_apply', ['recipe', 'apply'], {'recipeId': HEX, 'sourceRef': '1', 'ifDocument': 'd', 'ifState': 's', 'geometry': {'rotation': 1}}),
    ('edit_status', ['recipe', 'status'], {'compoundId': '../escape'}),
]
# Tools without arguments have no CLI-expressible invalid request.
ARGUMENT_FREE = {'doctor', 'doc_info', 'capabilities', 'schema'}


def run_parity(cli, mcp):
    """Proves per tool that CLI flags map to the MCP arguments object and are
    accepted or rejected identically. Needs a debug build: C1_CONTRACT_ECHO
    returns each decoded request instead of executing it, so nothing reaches Capture One."""
    with tempfile.TemporaryDirectory(prefix='c1-contract-parity-') as directory:
        env = {k: v for k, v in os.environ.items() if k != 'C1_READ_WORKFLOW'}
        env.update(C1_CONTRACT_ECHO='1', C1_REQUEST_DIR=directory, C1_PROGRESS='quiet')
        def cli_call(tool, argv, args):
            if argv[0] == 'recipe':
                request = Path(directory) / f'{tool}.json'
                request.write_text(json.dumps(args))
                argv = argv + ['--file', str(request)]
            return subprocess.run([str(cli), *argv, '--format', 'json'], capture_output=True, text=True, env=env, timeout=15)
        client = Client(mcp, env=env)
        try:
            tools = {t['name'] for t in client.request('tools/list', {})['tools']}
            assert {case[0] for case in ACCEPTED} == tools, tools ^ {case[0] for case in ACCEPTED}
            assert {case[0] for case in REJECTED} == tools - ARGUMENT_FREE, (tools - ARGUMENT_FREE) ^ {case[0] for case in REJECTED}
            for tool, argv, args in ACCEPTED:
                command = cli_call(tool, argv, args)
                assert command.returncode == 0, (tool, argv, command.stderr)
                result = client.tool(tool, args)
                assert not result.get('isError'), (tool, args, result)
                expected = {'tool': tool, 'arguments': args}
                assert json.loads(command.stdout) == expected, (tool, argv, command.stdout)
                assert json.loads(result['content'][0]['text']) == expected, (tool, args, result)
            for tool, argv, args in REJECTED:
                command = cli_call(tool, argv, args)
                assert command.returncode != 0, (tool, argv, command.stdout)
                result = client.tool(tool, args)
                assert result.get('isError'), (tool, args, result)
                cli_error = json.loads(command.stderr)['error']
                mcp_error = json.loads(result['content'][0]['text'])['error']
                assert (cli_error['code'], cli_error['message']) == (mcp_error['code'], mcp_error['message']), (tool, cli_error, mcp_error)
        finally:
            client.close()
    print(f'PASS: CLI/MCP parity for {len(ACCEPTED)} accepted and {len(REJECTED)} rejected requests across every tool')


if __name__ == '__main__':
    cli = Path(os.environ.get('C1_TEST_BIN', ROOT / '.build/debug/c1'))
    mcp = Path(os.environ.get('C1_TEST_MCP_BIN', ROOT / '.build/debug/c1-mcp'))
    run(cli, mcp)
    run_parity(cli, mcp)
