#!/usr/bin/env python3
"""Offline Catalog SQL qualification: real schema, synthetic records, real WAL/backup."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
from contract_test import Client, validate_response

ROOT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get('C1_TEST_BIN', ROOT / '.build/debug/c1'))
MCP = Path(os.environ.get('C1_TEST_MCP_BIN', ROOT / '.build/debug/c1-mcp'))
SCHEMA = json.loads((ROOT / 'Sources/CaptureOneCore/Resources/catalog-schema-16.8.5.json').read_text())

class CatalogReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'fixture.cocatalogdb'
        self.db = sqlite3.connect(self.path)
        for line in sorted(SCHEMA['schema'].splitlines(), key=lambda line: not line.startswith('table|')):
            self.db.execute(line.split('|', 3)[3])
        self.db.execute("INSERT INTO ZVERSIONINFO(Z_PK,ZVERSION,ZCOMPATIBLEVERSION,ZFORMAT) VALUES(1,160800,160800,'16.8.5.30 Pro Mac')")
        self.db.execute("INSERT INTO ZDOCUMENTCONTENT(Z_PK,ZDOCUMENTTYPE,ZDOCUMENTUUID) VALUES(1,1,'fixture-uuid')")
        self.db.execute("INSERT INTO ZPATHLOCATION(Z_PK,ZMACROOT,ZRELATIVEPATH,ZISRELATIVE) VALUES(1,'/','photos',0)")
        self.db.execute("INSERT INTO ZIMAGE(Z_PK,ZIMAGEUUID,ZIMAGEFILENAME,ZIMAGELOCATION,ZISINSIDECATALOG,ZDISPLAYNAME) VALUES(1,'image-uuid','a.CR3',1,0,'a')")
        for i in range(1, 4):
            self.db.execute('INSERT INTO ZVARIANT(Z_PK,ZIMAGE,ZVARIANTUUID,ZCOMBINEDSETTINGS) VALUES(?,1,?,?)', (i, f'variant-{i}', i))
            self.db.execute('INSERT INTO ZVARIANTLAYER(Z_PK,ZVARIANT,ZMETADATA,ZEXPOSURE) VALUES(?,?,?,?)', (i,i,i,i/10))
            self.db.execute('INSERT INTO ZVARIANTMETADATA(Z_PK,ZLAYER,ZBASIC_RATING) VALUES(?,?,?)', (i,i,i))
        for i in (1,2):
            self.db.execute('INSERT INTO ZCOLLECTION(Z_PK,ZNAME) VALUES(?,?)', (i, f'album-{i}'))
        self.db.execute('INSERT INTO ZIMAGEINCOLLECTION VALUES(47,1,1,1)')
        self.db.execute('INSERT INTO ZVARIANTINCOLLECTION VALUES(48,1,2,2)')
        self.db.execute('INSERT INTO ZVARIANTINCOLLECTION VALUES(48,2,1,2)')
        self.db.commit()

    def tearDown(self):
        self.db.close()
        self.temp.cleanup()

    def cli(self, command='variants', *args, error=False):
        p = subprocess.run([str(CLI), 'catalog', command, '--database', str(self.path), *map(str,args)], capture_output=True, text=True, timeout=20)
        if error:
            self.assertNotEqual(p.returncode,0,p.stdout)
            return p.stderr
        self.assertEqual(p.returncode,0,p.stderr)
        return json.loads(p.stdout)

    def test_identity_membership_and_settings(self):
        before = hashlib.sha256(self.path.read_bytes()).hexdigest()
        all_records = self.cli()['variants']
        self.assertEqual([r['variantDatabaseID'] for r in all_records],[1,2,3])
        self.assertEqual([r['originalPath'] for r in all_records],['/photos/a.CR3']*3)
        self.assertEqual(len(self.cli('variants','--collection-id',1)['variants']),3)
        self.assertEqual([r['variantDatabaseID'] for r in self.cli('variants','--collection-id',2)['variants']],[2])
        self.assertEqual([r['rating'] for r in self.cli('variants','--min-rating',2)['variants']],[2,3])
        result = self.cli('inspect')
        self.assertEqual(len(result['storedSettings']),3)
        self.assertEqual(result['schemaFingerprint'],SCHEMA['fingerprint'])
        self.assertNotIn('stateHash',json.dumps(result))
        self.assertEqual(before,hashlib.sha256(self.path.read_bytes()).hexdigest())
        self.cli('variants','--rating',1,'--min-rating',2,error=True)
        self.cli('variants','--collection-id',999,error=True)

    def test_single_variant_cli_mcp(self):
        command = [str(CLI), 'get', '2', '--database', str(self.path), '--format', 'json']
        before = hashlib.sha256(self.path.read_bytes()).hexdigest()
        p = subprocess.run(command, capture_output=True, text=True, timeout=20)
        self.assertEqual(p.returncode, 0, p.stderr)
        record = json.loads(p.stdout)
        self.assertEqual(record['variant']['Z_PK'], 2)
        self.assertEqual(record['storedSettings'][0]['ZEXPOSURE'], .2)
        self.assertEqual(record['storedMetadata'][0]['ZBASIC_RATING'], 2)
        self.assertTrue(record['storedStateOnly'])
        self.assertNotIn('stateHash', json.dumps(record))
        client = Client(MCP)
        try:
            result = client.tool('catalog_get', {'database': str(self.path), 'variantID': 2})
            self.assertFalse(result.get('isError'))
            self.assertEqual(json.loads(result['content'][0]['text'])['variant'], record['variant'])
            missing = client.tool('catalog_get', {'database': str(self.path), 'variantID': 999})
            self.assertTrue(missing['isError'])
            invalid = client.tool('catalog_get', {'database': str(self.path), 'variantID': 0})
            self.assertTrue(invalid['isError'])
        finally:
            client.close()
        self.assertEqual(before, hashlib.sha256(self.path.read_bytes()).hexdigest())

    def test_schema_and_session_rejection(self):
        self.db.execute('ALTER TABLE ZIMAGE ADD COLUMN FUTURE INTEGER'); self.db.commit()
        self.assertIn('Unsupported Catalog schema',self.cli(error=True))

    def test_document_type_rejection(self):
        self.db.execute('UPDATE ZDOCUMENTCONTENT SET ZDOCUMENTTYPE=0'); self.db.commit()
        self.assertIn('Unsupported Catalog schema',self.cli(error=True))

    def test_wal_parallel_snapshot_and_no_overwrite(self):
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('UPDATE ZVARIANTMETADATA SET ZBASIC_RATING=5 WHERE Z_PK=1'); self.db.commit()
        with concurrent.futures.ThreadPoolExecutor(4) as pool:
            results = list(pool.map(lambda _: self.cli(),range(8)))
        self.assertTrue(all(r['variants'][0]['rating']==5 for r in results))
        target = Path(self.temp.name)/'snapshot.cocatalogdb'
        result = self.cli('snapshot','--destination',target)
        self.assertEqual(result['snapshotPath'],str(target))
        with sqlite3.connect(target) as copied:
            self.assertEqual(copied.execute('PRAGMA integrity_check').fetchone()[0],'ok')
            self.assertEqual(copied.execute('SELECT ZBASIC_RATING FROM ZVARIANTMETADATA WHERE Z_PK=1').fetchone()[0],5)
        before=target.read_bytes()
        self.cli('snapshot','--destination',target,error=True)
        self.assertEqual(before,target.read_bytes())
        self.cli('snapshot','--destination',self.path,error=True)
        link=Path(self.temp.name)/'link.cocatalogdb'; link.symlink_to(self.path)
        self.cli('snapshot','--destination',link,error=True)

    def test_uncommitted_wal_is_not_visible(self):
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('UPDATE ZVARIANTMETADATA SET ZBASIC_RATING=5 WHERE Z_PK=1')
        self.assertEqual(self.cli()['variants'][0]['rating'],1)
        self.db.rollback()

    def test_embedded_null_text_is_preserved(self):
        self.db.execute('UPDATE ZVARIANTLAYER SET ZNAME=? WHERE Z_PK=1',('before\0after',)); self.db.commit()
        self.assertEqual(self.cli('inspect')['storedSettings'][0]['ZNAME'],'before\0after')

    def test_unknown_path_is_not_fabricated(self):
        self.db.execute('UPDATE ZIMAGE SET ZISINSIDECATALOG=1'); self.db.commit()
        self.assertIsNone(self.cli()['variants'][0]['originalPath'])

    def test_row_limit_and_locked_source_fail_without_partial_output(self):
        self.db.executemany('INSERT INTO ZVARIANT(Z_PK,ZIMAGE,ZVARIANTUUID) VALUES(?,1,?)', ((i,str(i)) for i in range(4,10002)))
        self.db.commit()
        self.assertIn('10000 records',self.cli(error=True))
        self.db.execute('BEGIN EXCLUSIVE')
        self.cli(error=True)
        self.db.rollback()

    def test_cli_database_route(self):
        result=subprocess.run([str(CLI),'variants','list','--database',str(self.path),'--rating','2'],capture_output=True,text=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual([r['rating'] for r in json.loads(result.stdout)['variants']],[2])
        result=subprocess.run([str(CLI),'variants','list','--database',str(self.path),'--selected'],capture_output=True,text=True,timeout=20)
        self.assertNotEqual(result.returncode,0)

    def test_mcp_parity(self):
        client=Client(MCP)
        try:
            schema=json.loads(client.tool('schema')['content'][0]['text'])
            for name in ['catalog_inspect','catalog_variants']:
                result=client.tool(name,{'database':str(self.path)})
                self.assertFalse(result.get('isError'),result)
                data=json.loads(result['content'][0]['text'])
                validate_response(data,schema['responses'][name])
                self.assertEqual(data['schemaFingerprint'],SCHEMA['fingerprint'])
        finally:
            client.close()
            for stream in (client.process.stdin, client.process.stdout, client.process.stderr): stream.close()

if __name__ == '__main__': unittest.main()
