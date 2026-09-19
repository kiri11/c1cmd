#!/usr/bin/env python3
"""Read-only, bounded upgraded Catalog stored-reader qualification; no Capture One calls.

Requires the retained upgraded Catalog schema/history. Reports checks and build/schema hashes only,
not photograph paths, settings, or identifiers. Does not qualify native freshness.
"""
import argparse
import base64
from contextlib import closing
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Tests'))
from contract_test import Client


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--mcp', type=Path, required=True)
    parser.add_argument('--database', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('output must be a new file')
    database = args.database.resolve()
    before = database.stat()
    manifests = [json.loads((ROOT / 'Sources/CaptureOneCore/Resources' / name).read_text()) for name in
                 ('catalog-schema-16.8.5.json', 'catalog-schema-upgraded-16.8.5.json')]

    def cli(*command, error=None):
        result = subprocess.run([str(args.cli.resolve()), *map(str, command), '--database', str(database)],
                                capture_output=True, text=True, timeout=30)
        if error:
            assert result.returncode and error in result.stderr, result.stderr
            assert not result.stdout, 'failed read returned partial stdout'
            return
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    with closing(sqlite3.connect(database.as_uri() + '?mode=ro', uri=True)) as db, closing(sqlite3.connect(':memory:')) as original:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON')
        deadline = time.monotonic() + 120
        db.set_progress_handler(lambda: int(time.monotonic() > deadline), 10000)
        db.execute('BEGIN')
        schema = '\n'.join('|'.join(row) for row in db.execute('SELECT type,name,tbl_name,sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type,name'))
        fingerprint = hashlib.sha256(schema.encode()).hexdigest()
        assert fingerprint == manifests[1]['sourceFingerprint']
        assert '\n'.join(line for line in schema.splitlines() if not line.startswith(('table|sqlite_stat1|', 'table|sqlite_stat4|'))) == manifests[1]['schema']
        history = [dict(r) for r in db.execute('SELECT ZVERSION,ZCOMPATIBLEVERSION,ZFORMAT FROM ZVERSIONINFO ORDER BY Z_PK')]
        assert history == manifests[1]['versionHistory']
        old = {line.split('|', 3)[1]: line.split('|', 3) for line in manifests[0]['schema'].splitlines()}
        new = {line.split('|', 3)[1]: line.split('|', 3) for line in manifests[1]['schema'].splitlines()}
        assert old.keys() == new.keys()
        for parts in sorted(old.values(), key=lambda p: p[0] != 'table'):
            original.execute(parts[3])
        reordered = []
        # These retained DDLs have no quoted literals or nested comma expressions.
        # Compare every full column/constraint clause, not just names or affinities.
        normalize = lambda sql: re.sub(r'\s*([(),])\s*', r'\1', re.sub(r'\s+', ' ', sql)).strip()
        for name, parts in new.items():
            assert parts[:3] == old[name][:3]
            if normalize(parts[3]) != normalize(old[name][3]):
                assert name in ('ZVARIANTLAYER', 'ZRETOUCHINGLAYER')
                assert sorted(normalize(parts[3]).split('(', 1)[1][:-1].split(',')) == sorted(normalize(old[name][3]).split('(', 1)[1][:-1].split(','))
                reordered.append(name)
            if parts[0] == 'table':
                lhs = original.execute(f'PRAGMA table_xinfo("{name}")').fetchall()
                rhs = db.execute(f'PRAGMA table_xinfo("{name}")').fetchall()
                assert sorted(tuple(r)[1:] for r in lhs) == sorted(tuple(r)[1:] for r in rhs)
                assert original.execute(f'PRAGMA foreign_key_list("{name}")').fetchall() == [tuple(r) for r in db.execute(f'PRAGMA foreign_key_list("{name}")')]
            else:
                assert original.execute(f'PRAGMA index_xinfo("{name}")').fetchall() == [tuple(r) for r in db.execute(f'PRAGMA index_xinfo("{name}")')]
        assert sorted(reordered) == ['ZRETOUCHINGLAYER', 'ZVARIANTLAYER']

        def rows(sql, values=()):
            return [{k: {'base64': base64.b64encode(v).decode()} if isinstance(v, bytes) else v
                     for k, v in dict(r).items()} for r in db.execute(sql, values)]

        ids = [r[0] for r in db.execute('SELECT Z_PK FROM ZVARIANT ORDER BY Z_PK')]
        valid_ids = set(ids)
        samples = {ids[int((len(ids)-1)*i/8)] for i in range(9)}
        retouch_ids = {r[0] for r in db.execute('SELECT DISTINCT ZVARIANT FROM ZRETOUCHINGLAYER WHERE ZVARIANT IS NOT NULL ORDER BY ZVARIANT')}
        samples.update(sorted(retouch_ids)[:10])
        client = Client(args.mcp.resolve())
        try:
            for variant_id in sorted(samples):
                variant = rows('SELECT * FROM ZVARIANT WHERE Z_PK=?', (variant_id,))[0]
                expected = {
                    'variant': variant,
                    'image': rows('SELECT * FROM ZIMAGE WHERE Z_PK=?', (variant['ZIMAGE'],))[0],
                    'storedSettings': rows('SELECT * FROM ZVARIANTLAYER WHERE ZVARIANT=? ORDER BY Z_PK', (variant_id,)),
                    'storedRetouching': rows('SELECT * FROM ZRETOUCHINGLAYER WHERE ZVARIANT=? ORDER BY Z_PK', (variant_id,)),
                }
                metadata_ids = {r['ZMETADATA'] for r in expected['storedSettings'] if r['ZMETADATA'] is not None}
                expected['storedMetadata'] = sorted([r for mid in metadata_ids for r in rows('SELECT * FROM ZVARIANTMETADATA WHERE Z_PK=?', (mid,))], key=lambda r: r['Z_PK'])
                actual = cli('get', variant_id, '--format', 'json')
                response = client.tool('catalog_get', {'database': str(database), 'variantID': variant_id})
                assert not response.get('isError'), response
                mcp = json.loads(response['content'][0]['text'])
                for observed in (actual, mcp):
                    assert observed['schemaFingerprint'] == fingerprint and observed['storedStateOnly']
                    assert not {'stateHash', 'nativeStateHash', 'openToken', 'workingRef'} & observed.keys()
                    for key, value in expected.items():
                        assert observed[key] == value, (variant_id, key)
            # Independently expand explicit image and variant membership in Python.
            memberships = {}
            for row in db.execute('SELECT ZCOLLECTION,ZVARIANT FROM ZVARIANTINCOLLECTION'):
                memberships.setdefault(row[0], set()).add(row[1])
            images = {}
            for row in db.execute('SELECT ZIMAGE,Z_PK FROM ZVARIANT'):
                images.setdefault(row[0], set()).add(row[1])
            for row in db.execute('SELECT ZCOLLECTION,ZIMAGE FROM ZIMAGEINCOLLECTION'):
                memberships.setdefault(row[0], set()).update(images.get(row[1], set()))
            candidates = [(cid, members & valid_ids) for cid, members in memberships.items()]
            collection_id, members = min((item for item in candidates if item[1]), key=lambda item: len(item[1]))
            assert 0 < len(members) <= 1000
            inventory = cli('catalog', 'variants', '--collection-id', collection_id)['variants']
            assert {r['variantDatabaseID'] for r in inventory} == members
            for record in inventory:
                variant = rows('SELECT * FROM ZVARIANT WHERE Z_PK=?', (record['variantDatabaseID'],))[0]
                layers = rows('SELECT * FROM ZVARIANTLAYER WHERE Z_PK=?', (variant['ZCOMBINEDSETTINGS'],))
                metadata = rows('SELECT * FROM ZVARIANTMETADATA WHERE Z_PK=?', (layers[0]['ZMETADATA'],)) if layers else []
                assert record['rating'] == (metadata[0]['ZBASIC_RATING'] if metadata else None)
                assert record['colorTag'] == ((metadata[0]['ZCOLOR_TAG_INDEX'] or 0) if metadata else 0)
            rating = next(r['rating'] for r in inventory if r['rating'] is not None)
            filtered = cli('catalog', 'variants', '--collection-id', collection_id, '--rating', rating)['variants']
            assert filtered == [r for r in inventory if r['rating'] == rating]
        finally:
            client.close()
            for stream in (client.process.stdin, client.process.stdout, client.process.stderr):
                stream.close()
        cli('catalog', 'variants', error='10000 records')
        after = database.stat()
        assert (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        report = {
            'cliSHA256': hashlib.sha256(args.cli.read_bytes()).hexdigest(),
            'mcpSHA256': hashlib.sha256(args.mcp.read_bytes()).hexdigest(),
            'schemaFingerprint': fingerprint, 'versionHistory': history,
            'fullDDLAndSQLiteMetadataCompared': True, 'reorderedTables': sorted(reordered),
            'sampledVariantsCLIAndMCPMatched': True, 'retouchingRecordsMatched': bool(samples & retouch_ids),
            'explicitCollectionMembershipMatched': True, 'ratingFilteringMatched': True,
            'oversizedInventoryRejectedWithoutPartialOutput': True,
            'sourceIdentitySizeMtimeUnchanged': True,
            'limits': ['Stored data compared with independent SQLite reads, not native Capture One state.',
                       'Bounded samples and one explicit collection; no exhaustive inventory through the reader.',
                       'Snapshot/WAL behavior covered by synthetic fixtures; source Catalog was not copied.',
                       'No mutation, freshness, RAW/profile/mask reconstruction, or future history qualification.'],
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open('x') as output:
            output.write(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
