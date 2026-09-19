#!/usr/bin/env python3
"""Measure stored-state visibility after acknowledged native writes on a NEW disposable Catalog.

Copies one RAW, requires zero open documents, never quits Capture One. Every mutation
uses c1 editing references and fresh tokens. Failed/uncertain mutations stop immediately
and leave the fixture open; there is no automatic rollback on error. Successful runs
restore baseline values before closing their owned fixture. SQLite observations use
short read-only transactions without immutable/nolock or forced checkpoints.
"""
import argparse
from contextlib import closing
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
QUERY = '''SELECT v.Z_PK AS variantID, v.ZVARIANTUUID AS uuid,
    m.ZBASIC_RATING AS rating, COALESCE(m.ZCOLOR_TAG_INDEX,0) AS colorTag,
    l.ZEXPOSURE AS exposure, l.ZCONTRAST AS contrast,l.ZSATURATION AS saturation,
    l.ZWHITEBALANCE AS whiteBalance, l.ZROTATION AS rotation,l.ZCROP AS crop
    FROM ZVARIANT v LEFT JOIN ZVARIANTLAYER l ON l.Z_PK=v.ZCOMBINEDSETTINGS
    LEFT JOIN ZVARIANTMETADATA m ON m.Z_PK=l.ZMETADATA ORDER BY v.Z_PK'''


def snapshot(path):
    with closing(sqlite3.connect(path.as_uri()+'?mode=ro', uri=True, timeout=.25)) as db:
        db.row_factory=sqlite3.Row
        db.execute('PRAGMA query_only=ON')
        return [dict(r) for r in db.execute(QUERY)]


def matches(row, expected):
    return row is not None and all(
        abs(row[k]-value) <= .0001 if isinstance(value,(float,int)) and isinstance(row.get(k),(float,int)) else row.get(k)==value
        for k,value in expected.items())


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--cli',default=str(ROOT/'.build/debug/c1'))
    p.add_argument('--raw',required=True)
    p.add_argument('--evidence',required=True)
    p.add_argument('--trials',type=int,default=3)
    p.add_argument('--observe-seconds',type=float,default=5)
    a=p.parse_args()
    if not 1<=a.trials<=20 or not 0<a.observe_seconds<=30: p.error('trials must be 1...20; observe-seconds must be >0...30')
    raw=Path(a.raw).resolve(); assert raw.is_file()
    evidence=Path(a.evidence).resolve(); evidence.mkdir(parents=True,exist_ok=False)
    events=[]
    def log(kind,**data):
        events.append(dict(event=kind,observedAt=datetime.now(timezone.utc).isoformat(),**data))
        (evidence/'events.json').write_text(json.dumps(events,indent=2)+'\n')
        print(kind,flush=True)
    def apple(body):
        command='tell application "/Applications/Capture One.app"\n'+body+'\nend tell'
        r=subprocess.run(['osascript','-s','s','-e',command],capture_output=True,text=True,timeout=150)
        if r.returncode: raise RuntimeError(r.stderr)
        return r.stdout.strip()
    require(apple('return count of documents')=='0', 'Close documents before running this fixture-owned probe.')
    require(json.loads(apple('return version'))=='16.8.5.30', 'Only Capture One 16.8.5.30 is qualified.')
    base=Path(tempfile.mkdtemp(prefix='c1-freshness-',dir='/private/tmp'))
    catalog=base/'freshness.cocatalog'
    fixture=base/('source'+raw.suffix); shutil.copy2(raw,fixture)
    source_hash=hashlib.sha256(raw.read_bytes()).hexdigest()
    environment=dict(os.environ,C1_CATALOG_WRITE_PATH=str(catalog))
    def cli(*args):
        r=subprocess.run([a.cli,*map(str,args),'--format','json'],env=environment,capture_output=True,text=True,timeout=150)
        if r.returncode:
            log('cli-failure',args=list(map(str,args)),stdout=r.stdout,stderr=r.stderr)
            raise RuntimeError('c1 failed; fixture retained. No retry or automatic restore.')
        return json.loads(r.stdout)
    log('fixture',base=str(base),sourceSHA256=source_hash,cliSHA256=hashlib.sha256(Path(a.cli).read_bytes()).hexdigest())
    apple(f'make new document with properties {{name:"freshness",kind:catalog,path:{json.dumps(str(base))}}}')
    apple('set destination type of import settings of current document to current location\n'
          'set import naming format of import settings of current document to "[Image Name]"\n'
          'set exclude duplicates of import settings of current document to false\n'
          'set backup of import settings of current document to false\n'
          'set auto adjust of import settings of current document to false\n'
          f'import current document source {{{json.dumps(str(fixture))}}}')
    variants=[]
    for _ in range(40):
        variants=cli('variants','list')
        if variants: break
        time.sleep(.25)
    assert len(variants)==1
    doc=cli('doc','info'); health=cli('doctor')
    require(Path(doc['documentPath']).resolve()==catalog.resolve(), 'The open document is not the newly created fixture.')
    require(health['allChecksPassed'] and health['writesEnabled'] and health['exactBuildMatched'], 'Fixture doctor checks did not pass.')
    native_id=variants[0]['id']; baseline=cli('get',native_id)
    require(Path(baseline['parentImagePath']).resolve()==fixture, 'The variant must reference the copied fixture RAW.')
    backup=base/'backup'; backup.mkdir()
    apple(f'backup now current document location {json.dumps(str(backup))} test integrity true optimize false')
    databases=list(catalog.glob('*.cocatalogdb')); assert len(databases)==1
    database=databases[0]
    stored=cli('catalog','inspect','--database',database)
    with closing(sqlite3.connect(database.as_uri()+'?mode=ro',uri=True)) as db:
        mode=db.execute('PRAGMA journal_mode').fetchone()[0]
    sdef=ET.parse('/Applications/Capture One.app/Contents/Resources/CaptureOne.sdef')
    barriers=[x.attrib for x in sdef.iter() if x.tag in ('command','property') and any(
        word in (x.get('name','')+' '+x.get('description','')).lower() for word in ('flush','modified','change count','dirty','save'))]
    log('environment',document=doc,journalMode=mode,schemaFingerprint=stored['schemaFingerprint'],saveOrRevisionCandidates=barriers)
    edit=cli('variant','edit',native_id,'--if-document',doc['openToken'],'--if-state',baseline['stateHash'])
    ref=edit['workingRef']
    observations=[]
    monitor=sqlite3.connect(database.as_uri()+'?mode=ro',uri=True,isolation_level=None,timeout=.25)
    def stamp():
        return dict(databaseMtimeNS=database.stat().st_mtime_ns, dataVersion=monitor.execute('PRAGMA data_version').fetchone()[0])
    def observe(label,acknowledged,expected,before_stamp):
        # Fresh connection/transaction each time: stale reads cannot be explained by
        # an observer holding a SQLite snapshot open across a native write.
        samples=[]
        limit=time.perf_counter()+a.observe_seconds
        while True:
            at=time.perf_counter(); rows=snapshot(database)
            row=next((r for r in rows if str(r['variantID'])==native_id),None)
            sample=dict(afterAcknowledgementMs=(at-acknowledged)*1000,row=row,matched=matches(row,expected),stamp=stamp())
            samples.append(sample)
            if sample['matched'] or time.perf_counter()>=limit: break
            time.sleep(.02)
        current=cli('get',ref)
        result=dict(label=label,expected=expected,firstReadMatched=samples[0]['matched'],
                    firstMatchMs=samples[-1]['afterAcknowledgementMs'] if samples[-1]['matched'] else None,
                    observedThroughMs=samples[-1]['afterAcknowledgementMs'],pollCount=len(samples),beforeMutationStamp=before_stamp,
                    samples=[sample for index,sample in enumerate(samples) if index==0 or index==len(samples)-1 or sample['row']!=samples[index-1]['row'] or sample['stamp']!=samples[index-1]['stamp']],
                    nativeAfter=dict(adjustments=current['adjustments'],metadata=current['metadata']))
        observations.append(result); log('observation',**result)
        return current
    current=cli('get',ref)
    for i in range(a.trials):
        rating=1+i%5; tag=1+i%7
        before_stamp=stamp()
        result=cli('metadata','set',ref,'--if-metadata-state',current['metadataStateHash'],'--rating',rating,'--color-tag',tag)
        ack=time.perf_counter()
        assert result['after']==dict(rating=rating,colorTag=tag)
        log('mutation-acknowledged',label=f'metadata-{i}',result=result)
        current=observe(f'metadata-{i}',ack,dict(rating=rating,colorTag=tag),before_stamp)
        assert current['metadata']['rating']==rating and current['metadata']['colorTag']==tag
        patch=dict(exposure=.125*(i+1),contrast=3*(1+i%10),saturation=-4*(i+1))
        before_stamp=stamp()
        result=cli('set',ref,'--if-state',current['stateHash'],*[f'{k}={v}' for k,v in patch.items()])
        ack=time.perf_counter()
        assert matches(result['after'],patch)
        log('mutation-acknowledged',label=f'tonal-{i}',result=result)
        current=observe(f'tonal-{i}',ack,patch,before_stamp)
        assert matches(current['adjustments'],patch)
    monitor.close()
    # Known-success mutations only. Fresh native tokens and explicit saved values.
    cli('metadata','set',ref,'--if-metadata-state',current['metadataStateHash'],
        '--rating',baseline['metadata']['rating'],'--color-tag',baseline['metadata']['colorTag'])
    current=cli('get',ref)
    cli('set',ref,'--if-state',current['stateHash'],*[f'{k}={baseline["adjustments"][k]}' for k in ('exposure','contrast','saturation')])
    restored=cli('get',ref)
    assert restored['adjustments']==baseline['adjustments'] and restored['metadata']==baseline['metadata']
    assert hashlib.sha256(raw.read_bytes()).hexdigest()==source_hash
    assert hashlib.sha256(fixture.read_bytes()).hexdigest()==source_hash
    assert cli('doc','info')['openToken']==doc['openToken']
    # End the owned workflow; never quit the application or close a user's document.
    apple(f'if (id of current document as text) is not {json.dumps(doc["documentId"])} then error "Document changed"\nclose current document')
    summary=dict(observedAt=datetime.now(timezone.utc).isoformat(),fixture=str(base),trials=len(observations),
        firstReadMismatches=sum(not r['firstReadMatched'] for r in observations),
        maximumObservedConvergenceMs=max((r['firstMatchMs'] for r in observations if r['firstMatchMs'] is not None),default=None),
        unconverged=sum(r['firstMatchMs'] is None for r in observations),
        staleDespiteUnchangedStamp=sum(not r['firstReadMatched'] and r['beforeMutationStamp']==r['samples'][0]['stamp'] for r in observations),
        journalMode=mode,schemaFingerprint=stored['schemaFingerprint'],cliSHA256=hashlib.sha256(Path(a.cli).read_bytes()).hexdigest(),sourceSHA256=source_hash,restored=True,closedOwnedDocument=True,
        limitation='CLI metadata and tonal writes only. No UI edits, imports/deletions under load, preview/export load, or screen-lock coverage. Negative results would not establish a universal freshness guarantee.')
    (evidence/'summary.json').write_text(json.dumps(summary,indent=2)+'\n'); print(json.dumps(summary,indent=2))

if __name__=='__main__': main()
