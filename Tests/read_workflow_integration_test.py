#!/usr/bin/env python3
"""Controlled read workflow qualification on owned Session/Catalog fixtures.
Requires zero open documents and C1_TEST_RAW_FIXTURE. Never quits Capture One;
failed/uncertain runs retain their fixture without retries or automatic restore.
"""
import json
import os
from pathlib import Path
import shutil
import sqlite3
import statistics
import subprocess
import tempfile
import time
from contextlib import closing
from catalog_integration_test import apple, sha, CLI, MCP
from contract_test import Client, validate_response


def main():
    raw = Path(os.environ['C1_TEST_RAW_FIXTURE']).resolve()
    source_sha = sha(raw)
    assert apple('return count of documents') == '0'
    assert json.loads(apple('return version')) == '16.8.5.30'
    evidence = Path(os.environ['C1_READ_WORKFLOW_EVIDENCE'])
    evidence.mkdir(parents=True, exist_ok=False)
    events = []
    contract = json.loads(subprocess.check_output([str(CLI), 'schema'], text=True))
    def log(event, **data):
        events.append(dict(event=event, **data))
        (evidence/'results.json').write_text(json.dumps(events, indent=2)+'\n')
        print(event, flush=True)
    log('environment', cliSHA256=sha(CLI), mcpSHA256=sha(MCP), sourceSHA256=source_sha)
    for kind in ('session', 'catalog'):
        base = Path(tempfile.mkdtemp(prefix='c1-read-workflow-', dir='/private/tmp'))
        env = dict(os.environ)
        for key in ('C1_READ_WORKFLOW', 'C1_PROFILE', 'C1_MCP_PROFILE', 'C1_CATALOG_WRITE_PATH'):
            env.pop(key, None)
        if kind == 'catalog': env['C1_CATALOG_WRITE_PATH'] = str(base/'reads.cocatalog')
        def cli(*args):
            start = time.perf_counter()
            p = subprocess.run([str(CLI), *map(str,args), '--format', 'json'], env=dict(env,C1_PROFILE='1'), capture_output=True, text=True, timeout=150)
            assert p.returncode == 0, (args,p.stdout,p.stderr)
            traces = [json.loads(line) for line in p.stderr.splitlines() if line.startswith('{') and 'c1-profile' in line]
            return json.loads(p.stdout), dict(elapsedMs=1000*(time.perf_counter()-start), handlers=[x['handler'] for x in traces if x['phase']=='apple_event'])
        def call(*args): return cli(*args)[0]
        log(kind+'-fixture', path=str(base))
        apple(f'make new document with properties {{name:"reads",kind:{kind},path:{json.dumps(str(base))}}}')
        fixture = (base/'reads/Capture' if kind == 'session' else base)/('source'+raw.suffix)
        fixture.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(raw,fixture)
        if kind == 'session':
            apple('set current collection of current document to collection "Capture" of current document')
        else:
            apple('set destination type of import settings of current document to current location\n'
                  'set import naming format of import settings of current document to "[Image Name]"\n'
                  'set backup of import settings of current document to false\n'
                  'set auto adjust of import settings of current document to false\n'
                  f'import current document source {{{json.dumps(str(fixture))}}}')
        for _ in range(40):
            rows = call('variants','list')
            if rows: break
            time.sleep(.25)
        assert len(rows)==1, rows
        native_id = rows[0]['id']
        doc = call('doc','info'); health = call('doctor')
        expected = base/'reads' if kind=='session' else base/'reads.cocatalog'
        assert Path(doc['documentPath']).resolve()==expected.resolve()
        assert health['allChecksPassed'] and health['writesEnabled'] and health['exactBuildMatched']
        baseline = call('get',native_id)
        assert Path(baseline['parentImagePath']).resolve()==fixture.resolve()
        if kind=='catalog':
            backup=base/'backup'; backup.mkdir()
            apple(f'backup now current document location {json.dumps(str(backup))} test integrity true optimize false')
        ref=call('variant','edit',native_id,'--if-document',doc['openToken'],'--if-state',baseline['stateHash'])['workingRef']
        started=call('read-session','begin'); wid=started['workflowId']
        assert started['active'] and started['sqliteEnabled']==(kind=='catalog'), started
        client=Client(MCP,env=env,timeout=150)
        def tool(name,args):
            r=client.tool(name,args); assert not r.get('isError'),r
            value=json.loads(r['content'][0]['text'])
            validate_response(value,contract['responses'][name],name)
            return value
        try:
            assert tool('read_session_status',{'readWorkflow':wid})['active']
            first=call('get',native_id,'--read-workflow',wid)
            assert 'stateHash' not in first and first['readObservation']['workflowId']==wid,first
            assert 'stateHash' in call('get',native_id)
            assert 'stateHash' in call('get',native_id,'--read-workflow','unrelated')
            assert 'stateHash' in call('get',native_id,'--read-workflow',wid,'--live')
            assert 'stateHash' in tool('get',{'ref':ref,'readWorkflow':wid})
            warm,profile=cli('get',native_id,'--read-workflow',wid)
            assert profile['handlers'] and 'getAdjustmentsBatch' not in profile['handlers'],profile
            assert tool('get',{'ref':native_id,'readWorkflow':wid})['adjustments']==warm['adjustments']
            assert len(tool('dump',{'readWorkflow':wid}))==1
            assert 'stateHash1' not in tool('diff',{'ref1':native_id,'ref2':native_id,'readWorkflow':wid})
            current=call('get',ref)
            call('metadata','set',ref,'--if-metadata-state',current['metadataStateHash'],'--rating',5,'--color-tag',2)
            filtered=tool('variants_list',{'readWorkflow':wid,'minRating':4})
            assert [x['id'] for x in filtered]==[native_id] and filtered[0]['rating']==5,filtered
            current=call('get',ref)
            changed=call('set',ref,'--if-state',current['stateHash'],'exposure=0.375','contrast=3','saturation=-4')
            overlaid,profile=cli('get',native_id,'--read-workflow',wid)
            assert overlaid['adjustments']==changed['after'] and overlaid['metadata']['rating']==5,overlaid
            assert profile['handlers'] and 'getAdjustmentsBatch' not in profile['handlers'],profile
            log(kind+'-overlay',start=started,read=overlaid,profile=profile)
            timings={}
            for command,args in [('get',[native_id]),('variants',['list'])]:
                timings[command]={}
                for mode,flags in [('workflow',['--read-workflow',wid]),('live',['--live'])]:
                    samples=[cli(command,*args,*flags)[1]['elapsedMs'] for _ in range(3)]
                    timings[command][mode]=dict(samplesMs=samples,medianMs=statistics.median(samples))
            log(kind+'-timings',timings=timings)
            database=next(expected.glob('*.cosessiondb' if kind=='session' else '*.cocatalogdb'))
            def stored():
                with closing(sqlite3.connect(database.as_uri()+'?mode=ro',uri=True)) as db:
                    return db.execute('SELECT v.Z_PK,l.ZEXPOSURE,m.ZBASIC_RATING FROM ZVARIANT v LEFT JOIN ZVARIANTLAYER l ON l.Z_PK=v.ZCOMBINEDSETTINGS LEFT JOIN ZVARIANTMETADATA m ON m.Z_PK=l.ZMETADATA').fetchall()
            log(kind+'-stored-immediate',rows=stored())
            if kind=='catalog':
                print('Waiting for the 60-second SQL catch-up boundary',flush=True)
                time.sleep(61)
                caught,profile=cli('get',native_id,'--read-workflow',wid)
                assert caught['adjustments']==changed['after'] and caught['metadata']['rating']==5,caught
                assert profile['handlers'] and 'getAdjustmentsBatch' not in profile['handlers'],profile
                log('catalog-catch-up',read=caught,profile=profile,stored=stored())
            tool('read_session_end',{'readWorkflow':wid})
            assert 'stateHash' in call('get',native_id,'--read-workflow',wid)
            assert tool('read_session_status',{'readWorkflow':wid})=={'active':False}
            # Restore only acknowledged successful edits, using new native tokens.
            current=call('get',ref)
            call('metadata','set',ref,'--if-metadata-state',current['metadataStateHash'],'--rating',baseline['metadata']['rating'],'--color-tag',baseline['metadata']['colorTag'])
            current=call('get',ref)
            call('set',ref,'--if-state',current['stateHash'],*[f'{k}={baseline["adjustments"][k]}' for k in ('exposure','contrast','saturation')])
            restored=call('get',ref)
            assert restored['adjustments']==baseline['adjustments'] and restored['metadata']==baseline['metadata']
            assert sha(raw)==source_sha and sha(fixture)==source_sha
            assert call('doc','info')['openToken']==doc['openToken']
            apple(f'if (id of current document as text) is not {json.dumps(doc["documentId"])} then error "Document changed"\nclose current document')
            if kind=='catalog':
                offline,profile=cli('get',native_id,'--database',database)
                assert offline['storedStateOnly'] and not profile['handlers'],(offline,profile)
                assert tool('catalog_get',{'database':str(database),'variantID':int(native_id)})['variant']==offline['variant']
                log('closed-catalog',profile=profile,variant=offline['variant'])
            else:
                log('session-storage',rows=stored(),sidecars=[str(p.relative_to(expected)) for p in expected.rglob('*.cos')])
            log(kind+'-passed',restored=True,rawUnchanged=True,closedOwnedDocument=True)
        finally:
            client.close()
    log('passed',omitted='No UI edits, load/large Catalog matrix, or recovery fault injection; mutation/recovery implementation unchanged.')

if __name__=='__main__': main()
