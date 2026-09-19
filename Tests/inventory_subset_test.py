#!/usr/bin/env python3
"""Read-only subset assertions, called sequentially inside the inventory fixture suite."""
import json
import os
from pathlib import Path
import subprocess
import time
from contract_test import Client

ROOT = Path(__file__).resolve().parents[1]


def run(records):
    cli = Path(os.environ.get('C1_TEST_BIN', ROOT / '.build/debug/c1'))
    mcp = Path(os.environ.get('C1_TEST_MCP_BIN', ROOT / '.build/debug/c1-mcp'))
    records = records[:100]
    ids = [row['id'] for row in reversed(records)]
    by_id = {row['id']: row for row in records}
    durations = {}

    def read(label, *flags, error=False):
        started = time.monotonic()
        response = subprocess.run([str(cli), 'variants', 'list', '--ids', ','.join(ids),
                                   '--batch-size', '3', '--format', 'json', *flags],
                                  capture_output=True, text=True, timeout=120)
        durations[label] = time.monotonic() - started
        if error:
            assert response.returncode != 0 and not response.stdout.strip(), response
            return
        assert response.returncode == 0, response.stderr
        return json.loads(response.stdout)

    rows = read('minimal')
    assert [r['id'] for r in rows] == ids
    assert all(set(row) == {'id', 'rating', 'parentImagePath'} for row in rows)
    for row in rows:
        assert row == {key: by_id[row['id']][key] for key in row}
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
    finally:
        client.close()
    ids.append('missing-subset-id')
    read('missing', error=True)
    return {'label': 'bounded-id-subset', 'variants': len(records), 'seconds': durations,
            'checks': 'ordered minimal, exact rating/path, summary, collection, selection, MCP parity, missing ID fails whole read'}
