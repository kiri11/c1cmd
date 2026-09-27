#!/usr/bin/env python3
"""Read-only subset assertions, called sequentially inside the inventory fixture suite."""
import json
import os
from pathlib import Path
import subprocess
import time
from contract_test import Client

ROOT = Path(__file__).resolve().parents[1]


def run(records, status_dir):
    cli = Path(os.environ.get('C1_TEST_BIN', ROOT / '.build/debug/c1'))
    env = dict(os.environ, C1_REQUEST_DIR=str(status_dir), C1_PROGRESS='json')
    mcp = Path(os.environ.get('C1_TEST_MCP_BIN', ROOT / '.build/debug/c1-mcp'))
    records = records[:100]
    ids = [row['id'] for row in reversed(records)]
    by_id = {row['id']: row for row in records}
    durations = {}

    def status(request_id):
        response = subprocess.run([str(cli), 'request', 'status', request_id, '--format', 'json', '--quiet'],
                                  capture_output=True, text=True, timeout=30, env=env)
        assert response.returncode == 0, response.stderr
        return json.loads(response.stdout)

    def read(label, *flags, error=False, request=None):
        started = time.monotonic()
        response = subprocess.run([str(cli), 'variants', 'list', '--ids', ','.join(ids),
                                   '--batch-size', '3', '--format', 'json', *flags],
                                  capture_output=True, text=True, timeout=120, env=env)
        durations[label] = time.monotonic() - started
        if error:
            assert response.returncode != 0 and not response.stdout.strip(), response
            return json.loads(response.stderr[response.stderr.index('{\n'):])['error']
        assert response.returncode == 0, response.stderr
        if request is not None:
            request.update(json.loads(response.stderr.splitlines()[0]))
        return json.loads(response.stdout)

    first = {}
    rows = read('minimal', request=first)
    assert [r['id'] for r in rows] == ids
    assert all(set(row) == {'id', 'rating', 'parentImagePath'} for row in rows)
    for row in rows:
        assert row == {key: by_id[row['id']][key] for key in row}
    # Both bounded passes report every row; only revalidated matches are confirmed.
    final = status(first['requestId'])
    assert final['status'] == 'completed' and final['phase'] == 'confirmed' and final['pass'] == 2, final
    assert final['candidatesScanned'] == final['revalidatedRows'] == len(ids), final
    assert final['unconfirmedMatches'] == final['matchesFound'] == len(rows), final
    rating = rows[0]['rating']
    expected = [row for row in rows if row['rating'] == rating]
    assert read('exact', '--rating', str(rating)) == expected
    path = rows[0]['parentImagePath']
    assert read('path', '--parent-path', path) == [r for r in rows if r['parentImagePath'] == path]
    assert read('absent-path', '--parent-path', '/nonexistent-subset.CR3') == []
    summaries = read('summary', '--fields', 'summary')
    for row in summaries:
        assert row == {key: by_id[row['id']][key] for key in row}
    assert read('collection', '--collection', 'Capture') == rows
    selected = read('selection', '--selected')
    assert [r['id'] for r in selected] == [i for i in ids if by_id[i]['isSelected']]
    client = Client(mcp, timeout=120)
    try:
        result = client.tool('variants_list', {'ids': ids, 'rating': rating, 'batchSize': 3})
        assert not result.get('isError'), result
        assert json.loads(result['content'][0]['text']) == expected
        bad = client.tool('variants_list', {'ids': [ids[0], 'missing-subset-id']})
        assert bad.get('isError'), bad
        bad_error = json.loads(bad['content'][0]['text'])['error']
        assert bad_error['code'] == 'variant-not-found' and bad_error['missingIds'] == ['missing-subset-id'], bad_error
    finally:
        client.close()
    # A fresh session's Selects collection is empty, so every present ID is outside it.
    outside = read('out-of-scope', '--collection', 'Selects', error=True)
    assert outside['code'] == 'variant-not-found' and outside['missingIds'] == [] and outside['outOfScopeIds'] == ids, outside
    ids.append('missing-subset-id')
    missing = read('missing', error=True)
    assert missing['code'] == 'variant-not-found' and missing['missingIds'] == ['missing-subset-id'], missing
    assert 'outOfScopeIds' not in missing, missing
    stored = status(missing['requestId'])
    assert stored['status'] == 'failed' and stored['pass'] == 1 and stored['candidatesScanned'] == len(ids), stored
    assert stored['errorCode'] == 'variant-not-found' and stored['missingIds'] == ['missing-subset-id'], stored
    assert 'missing-subset-id' in stored['errorMessage'] and 'matchesFound' in stored and stored['matchesFound'] == 0, stored
    return {'label': 'bounded-id-subset', 'variants': len(records), 'seconds': durations,
            'checks': 'ordered minimal, per-pass status counters, exact rating/path, summary, collection, selection, MCP parity, '
                      'missing and out-of-collection IDs listed and stored in request status'}
