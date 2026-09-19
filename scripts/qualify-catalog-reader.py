#!/usr/bin/env python3
"""Read-only native/SQL comparisons on an already-open disposable Catalog.

Also checks reading a standalone backup while the original Catalog remains open.
Does not open/close documents, change settings, or request Capture One shutdown.
"""
import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
import sqlite3
import subprocess
import tempfile

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--cli',required=True)
p.add_argument('--database',required=True)
p.add_argument('--output',required=True)
a=p.parse_args()
def cli(*args):
    r=subprocess.run([a.cli,*map(str,args),'--format','json'],capture_output=True,text=True,timeout=30)
    if r.returncode: raise RuntimeError(r.stderr)
    return json.loads(r.stdout)

doc=cli('doc','info')
assert not doc['isSession'] and doc['appVersion']=='16.8.5.30'
assert Path(a.database).resolve().parent==Path(doc['documentPath']).resolve()
stored=cli('catalog','inspect','--database',a.database)
summaries=cli('catalog','variants','--database',a.database)['variants']
raw_hashes={r['originalPath']:hashlib.sha256(Path(r['originalPath']).read_bytes()).hexdigest() for r in summaries}
settings={r['Z_PK']:r for r in stored['storedSettings']}
comparisons=[]
for r in summaries:
    live=cli('get',r['variantDatabaseID'])
    layer=settings[r['combinedSettingsID']]
    for name in ['exposure','contrast','saturation']:
        assert abs(live['adjustments'][name]-layer['Z'+name.upper()])<0.0001,(r,name,live,layer)
    comparisons.append({'variantDatabaseID':r['variantDatabaseID'],'variantUUID':r['variantUUID'],
                        'nativeAdjustments':{n:live['adjustments'][n] for n in ['exposure','contrast','saturation']},
                        'combinedLayerDatabaseID':r['combinedSettingsID']})
collections={r['Z_PK']:r for r in stored['collections']}
collection_results=[]
for cid in sorted({r['ZCOLLECTION'] for r in stored['imageMembership']}):
    collection=collections[cid]
    if not collection['ZNAME']: continue
    # Explicit image membership fixture only; do not assert virtual collection equivalence.
    native=cli('variants','list','--collection',collection['ZNAME'])
    sql=cli('catalog','variants','--database',a.database,'--collection-id',cid)['variants']
    assert {r['id'] for r in native}=={str(r['variantDatabaseID']) for r in sql}
    collection_results.append({'collectionDatabaseID':cid,'name':collection['ZNAME'],'variantCount':len(sql)})
with tempfile.TemporaryDirectory(prefix='c1-stored-archive-') as tmp:
    target=Path(tmp)/'archive.cocatalogdb'
    snapshot=cli('catalog','snapshot','--database',a.database,'--destination',target)
    archived=cli('catalog','inspect','--database',target)
    for key in ['images','variants','imageMembership','variantMembership','storedSettings','storedMetadata','storedRetouching']:
        assert archived[key]==stored[key],key
    assert archived['databaseDocumentUUID']==stored['databaseDocumentUUID']
    with sqlite3.connect(f'file:{target}?mode=ro',uri=True) as c:
        assert c.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
    backup_bytes=target.stat().st_size
assert cli('doc','info')['openToken']==doc['openToken']
assert all(hashlib.sha256(Path(path).read_bytes()).hexdigest()==digest for path,digest in raw_hashes.items())
report={'observedAt':datetime.now(timezone.utc).isoformat(),'cliSHA256':hashlib.sha256(Path(a.cli).read_bytes()).hexdigest(),'appVersion':doc['appVersion'],'databaseDocumentUUID':stored['databaseDocumentUUID'],
        'schemaFingerprint':stored['schemaFingerprint'],'comparisons':comparisons,'collectionComparisons':collection_results,
        'snapshotIntegrity':'ok','standaloneSnapshotInspectedWhileOriginalOpen':True,'snapshotBytes':backup_bytes,
        'rawHashesUnchanged':raw_hashes,
        'limits':['Existing small disposable fixture; exposure/contrast/saturation values were zero.',
                  'Explicit variant-only membership has synthetic regression coverage, not native fixture coverage.',
                  'No stored white-balance-to-Kelvin conversion, mask reconstruction, Session support, or freshness guarantee.']}
Path(a.output).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
