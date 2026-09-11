#!/usr/bin/env python3
"""Crop/rotation CLI + MCP qualification in a disposable Session; originals preserved.
Requires C1_TEST_RAW_FIXTURE and zero open documents. Evidence retained in C1_GEOMETRY_EVIDENCE.
"""
import hashlib, json, os, shutil, subprocess, sys, tempfile, time, uuid
from pathlib import Path
from contract_test import Client, validate_response
ROOT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get('C1_TEST_BIN',ROOT / '.build/debug/c1'))
MCP = Path(os.environ.get('C1_TEST_MCP_BIN',ROOT / '.build/debug/c1-mcp'))
RAW = Path(os.environ['C1_TEST_RAW_FIXTURE'])
EVIDENCE = Path(os.environ.get('C1_GEOMETRY_EVIDENCE', tempfile.mkdtemp(prefix='c1-geometry-evidence-',dir='/private/tmp')))
EVIDENCE.mkdir(parents=True,exist_ok=True)

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def log(event, **data):
    with (EVIDENCE/'events.jsonl').open('a') as f: f.write(json.dumps(dict(event=event,**data))+'\n'); f.flush(); os.fsync(f.fileno())
def apple(body):
    p=subprocess.run(['osascript','-s','s','-e','tell application "/Applications/Capture One.app"\n'+body+'\nend tell'],capture_output=True,text=True,timeout=90)
    assert p.returncode == 0,p.stderr
    return p.stdout.strip()
def cli(*args, error=None):
    p=subprocess.run([str(CLI),*map(str,args),'--format','json'],capture_output=True,text=True,timeout=90)
    result=json.loads(p.stderr if p.returncode else p.stdout)
    if error: assert result['error']['code']==error,result
    else: assert p.returncode==0,result
    return result
assert apple('return count of documents')=='0','Close documents before qualification'
assert json.loads(apple('return version'))=='16.8.5.30'
base=Path(tempfile.mkdtemp(prefix='c1-geometry-live-',dir='/private/tmp'))
apple(f'make new document with properties {{name:"geometry",kind:session,path:"{base}"}}')
session=base/'geometry'; fixture=session/'Capture'/RAW.name
original_sha=sha(RAW);shutil.copy2(RAW,fixture)
apple('set current collection of current document to collection "Capture" of current document')
for _ in range(40):
    variants=cli('variants','list')
    if variants: break
    time.sleep(.5)
assert cli('doctor')['allChecksPassed']
doc=cli('doc','info');original=cli('get',variants[0]['id'])
assert original.get('geometry'),original
contract=json.loads(subprocess.check_output([str(CLI),'schema'],text=True))
cloned=cli('variant','clone',original['id']); ref=cloned['workingRef']
log('environment',doc=doc,source=original,clone=cloned,rawSHA256=original_sha,cliSHA256=sha(CLI),mcpSHA256=sha(MCP))
client=Client(MCP)
def tool(name,args):
    result=client.tool(name,args)
    assert not result.get('isError'),result
    data=json.loads(result['content'][0]['text'])
    validate_response(data,contract['responses'][name],name)
    return data,result
try:
    initial=cli('get',ref)
    cli('geometry','set',original['id'],'--if-geometry-state',initial['geometryStateHash'],'--rotation',1,error='unmanaged-variant')
    first=cli('geometry','set',ref,'--if-geometry-state',initial['geometryStateHash'],'--rotation',2,'--aspect-ratio',1.5)
    log('landscape',result=first)
    assert abs(first['after']['crop']['width']/first['after']['crop']['height']-1.5)<.001
    assert cli('get',ref)['stateHash']==initial['stateHash']
    cli('geometry','set',ref,'--if-geometry-state',initial['geometryStateHash'],'--rotation',1,error='state-changed')
    preview=cli('preview',ref);log('preview-landscape',result=preview)
    assert abs(preview['width']/preview['height']-1.5)<.003
    second,_=tool('geometry_set',{'workingRef':ref,'ifGeometryState':first['geometryStateHash'],'rotation':-3,'aspectRatio':.75})
    log('portrait',result=second)
    preview,_=tool('preview',{'ref':ref});log('preview-portrait',result=preview)
    assert abs(preview['width']/preview['height']-.75)<.003
    count=len(cli('variants','list'))
    context,_=tool('preview',{'ref':ref,'fullFrame':True});log('preview-context',result=context)
    assert context['contextSourceRef']==ref
    assert len(cli('variants','list'))==count,'Context clone leaked'
    assert cli('get',ref)['geometryStateHash']==second['geometryStateHash']
    diff,_=tool('diff',{'ref1':ref});assert diff['geometryDiff']['rotation']['after']==-3
    dump,_=tool('dump',{});assert all(r.get('geometry') for r in dump)
    restored,_=tool('geometry_set',{'workingRef':ref,'ifGeometryState':second['geometryStateHash'],'crop':initial['geometry']['crop'],'rotation':initial['geometry']['rotation']})
    assert restored['after']['crop']==initial['geometry']['crop']
    # Explicit non-centered composition coordinates, preserved on readback.
    current=cli('get',ref); rect=dict(centerX=2700,centerY=2100,width=2400,height=3200)
    offset,_=tool('geometry_set',{'workingRef':ref,'ifGeometryState':current['geometryStateHash'],'crop':rect})
    assert offset['after']['crop']==rect
    log('off-center',result=offset)
    proposal_file=EVIDENCE/'proposal.json'
    proposal_file.write_text(json.dumps([{'sourceRef':original['id'],'ifGeometryState':original['geometryStateHash'],
        'orientation':'landscape','rotation':0,'rationale':'Technical workflow fixture; photographer review pending.'}]))
    example=Path(os.environ.get('C1_TEST_CROP_EXAMPLE',ROOT/'examples/crop-proposals.py'))
    completed=subprocess.run([sys.executable,str(example),str(proposal_file),'--output-dir',str(EVIDENCE/'reviews'),'--c1-bin',str(CLI)],capture_output=True,text=True,timeout=120)
    assert completed.returncode==0,completed.stderr
    proposal_result=json.loads(completed.stdout)
    review=json.loads(Path(proposal_result['reviewRecord']).read_text())
    assert review['reviewStatus']=='unreviewed' and review['beforePreview'] and review['afterPreview']
    cli('variant','delete',proposal_result['workingRef'])
    log('review-example',record=proposal_result['reviewRecord'])
    # Qualify already-oriented images on managed clones; record native fixture setup before dispatch.
    journal=session/'.c1/journal.jsonl'
    binding=json.loads(journal.read_text().splitlines()[0])
    def native_fixture(label, body):
        entry=dict(binding,operationId=str(uuid.uuid4()),operationType='geometry-fixture-'+label,workingRef=ref,nativeVariantId=cloned['cloneVariantId'],status='pending')
        def append():
            with journal.open('a') as f:f.write(json.dumps(entry)+'\n');f.flush();os.fsync(f.fileno())
        append()
        result=apple(f'set v to variant id "{cloned["cloneVariantId"]}" of current document\n'+body)
        entry['status']='succeeded';append()
        return result
    # A selected UI ratio must not override an explicit native crop rectangle.
    native_fixture('ratio', '''set ratioNames to get available crop aspect ratios of v
    repeat with ratioName in ratioNames
        if (ratioName as text) contains "3" and (ratioName as text) contains "2" then
            set crop aspect ratio of v to ratioName as text
            return crop aspect ratio of v
        end if
    end repeat
    error "No 3:2 aspect ratio preset available"''')
    current=cli('get',ref)
    assert current['geometry'].get('aspectRatioName')
    result,_=tool('geometry_set',{'workingRef':ref,'ifGeometryState':current['geometryStateHash'],'rotation':2,'aspectRatio':.75})
    assert result['after']['aspectRatioName']==current['geometry']['aspectRatioName']
    pr,_=tool('preview',{'ref':ref});assert abs(pr['width']/pr['height']-.75)<.003
    log('aspect-ratio-preset',result=result,preview=pr)
    for label, setter in [('perspective','keystone vertical of adjustments'),('distortion','distortion of lens correction')]:
        native_fixture(label,f'set {setter} of v to 1')
        current=cli('get',ref)
        assert current.get('geometryUnavailableReason'),current
        rejection=cli('geometry','set',ref,'--if-geometry-state',current['geometryStateHash'],'--aspect-ratio',1.5,error='invalid-request')
        assert cli('get',ref)==current,'Rejected request changed existing corrections'
        log('unsupported-'+label,rejection=rejection,observed=current)
        native_fixture(label+'-restore',f'set {setter} of v to 0')
    for orientation in [90,180,270]:
        entry=dict(binding,operationId=str(uuid.uuid4()),operationType='geometry-fixture-orientation',workingRef=ref,nativeVariantId=cloned['cloneVariantId'],status='pending')
        def append():
            with journal.open('a') as f:f.write(json.dumps(entry)+'\n');f.flush();os.fsync(f.fileno())
        append()
        apple(f'set orientation of adjustments of variant id "{cloned["cloneVariantId"]}" of current document to {orientation}')
        entry['status']='succeeded';append()
        g=cli('get',ref)
        ratio=.75 if orientation in (90,270) else 1.5
        result,_=tool('geometry_set',{'workingRef':ref,'ifGeometryState':g['geometryStateHash'],'rotation':2,'aspectRatio':ratio})
        assert result['after']['orientation']==orientation
        pr,_=tool('preview',{'ref':ref}); assert abs(pr['width']/pr['height']-ratio)<.003
        log('orientation',orientation=orientation,result=result,preview=pr)
    for angle in [-45,-10,0,10,45]:
        current=cli('get',ref)
        result,_=tool('geometry_set',{'workingRef':ref,'ifGeometryState':current['geometryStateHash'],'rotation':angle,'aspectRatio':.75})
        assert abs(result['after']['rotation']-angle)<.001
        if abs(angle)==45:
            pr,_=tool('preview',{'ref':ref});assert abs(pr['width']/pr['height']-.75)<.003
        log('rotation-boundary',angle=angle,result=result)
    assert cli('get',original['id'])==original,'Original variant changed'
    assert sha(RAW)==original_sha and sha(fixture)==original_sha
    cli('variant','delete',ref)
    log('passed',originalUnchanged=True,rawSHA256=sha(fixture))
    shutil.copy2(journal,EVIDENCE/'journal.jsonl')
    apple('close current document')
    print('PASS: geometry CLI/MCP, ratios, rotations, off-center crop, full-frame context, orientation, original/RAW preservation')
    print(EVIDENCE)
except BaseException as e:
    log('failed',error=str(e));raise
finally:client.close()
