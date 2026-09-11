#!/usr/bin/env python3
"""Apply explicit agent/photographer crop proposals and retain unreviewed sidecars.

Input is a JSON list with sourceRef, ifGeometryState (from source get), orientation
(landscape/portrait), rationale, and crop and/or rotation. With no explicit crop,
a centered crop fits the orientation's usual ratio. The caller judges composition.
Use ratioException (a reason) to propose another ratio. Never automatically retry.
"""
import argparse, datetime, json, math, os, subprocess, uuid
from pathlib import Path


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('proposals',type=Path)
    p.add_argument('--output-dir',type=Path,required=True)
    p.add_argument('--c1-bin',default='c1')
    args=p.parse_args()
    proposals=json.loads(args.proposals.read_text())
    if not isinstance(proposals,list):raise ValueError('Proposals must be a JSON list')
    def run(*words):
        result=subprocess.run([args.c1_bin,*map(str,words),'--format','json'],capture_output=True,text=True)
        payload=json.loads(result.stderr if result.returncode else result.stdout)
        if result.returncode:raise RuntimeError(json.dumps(payload))
        return payload
    # Validate input shape before cloning; native bounds are checked by c1.
    for proposal in proposals:
        if not isinstance(proposal,dict):raise ValueError('Each proposal must be an object')
        if not {'sourceRef','ifGeometryState','orientation','rationale'} <= proposal.keys():raise ValueError('Missing proposal identity or rationale')
        if proposal.keys()-{'sourceRef','ifGeometryState','orientation','rationale','crop','rotation','ratioException'}:raise ValueError('Unknown proposal field')
        if any(not isinstance(proposal[k],str) or not proposal[k].strip() for k in ['sourceRef','ifGeometryState','rationale']):raise ValueError('Identity and rationale must be nonempty strings')
        if 'ratioException' in proposal and (not isinstance(proposal['ratioException'],str) or not proposal['ratioException'].strip()):raise ValueError('Explain the ratio exception')
        if proposal['orientation'] not in ['landscape','portrait']:raise ValueError('Specify landscape or portrait after inspecting the image')
        def finite_number(value):return type(value) in (int,float) and math.isfinite(value)
        if 'rotation' in proposal and (not finite_number(proposal['rotation']) or abs(proposal['rotation'])>45):raise ValueError('Rotation must be finite and between -45 and 45 degrees')
        ratio=1.5 if proposal['orientation']=='landscape' else .75
        if 'crop' in proposal:
            c=proposal['crop']
            if not isinstance(c,dict) or set(c)!={'centerX','centerY','width','height'} or not all(finite_number(v) for v in c.values()) or c['height']<=0 or c['width']<=0:raise ValueError('Invalid crop rectangle')
            if abs(c['width']-ratio*c['height'])>2 and not proposal.get('ratioException'):raise ValueError('Explain an exception to the usual ratio')
    health=run('doctor');assert health['allChecksPassed'] and health['isSession'] and health['exactBuildMatched']
    document=run('doc','info')
    args.output_dir.mkdir(parents=True,exist_ok=True)
    for proposal in proposals:
        path=args.output_dir/(str(uuid.uuid4())+'.json')
        record={'proposal':proposal,'document':document,'reviewStatus':'unreviewed','createdAt':datetime.datetime.now(datetime.timezone.utc).isoformat()}
        def save():
            temp=path.with_suffix('.tmp')
            with temp.open('w') as f:json.dump(record,f,indent=2);f.flush();os.fsync(f.fileno())
            temp.replace(path)
        save()
        try:
            source=run('get',proposal['sourceRef'])
            if source.get('geometryStateHash')!=proposal['ifGeometryState']:raise ValueError('Source geometry changed since proposal; re-inspect it')
            record['source']=source
            record['clone']=run('variant','clone',proposal['sourceRef']);save()
            ref=record['clone']['workingRef'];current=run('get',ref)
            if current.get('geometryStateHash')!=source['geometryStateHash']:raise ValueError('Clone no longer matches proposal source')
            record['beforePreview']=run('preview',ref);save()
            words=['geometry','set',ref,'--if-geometry-state',current['geometryStateHash']]
            if 'rotation' in proposal:words+=['--rotation',proposal['rotation']]
            if 'crop' in proposal:words+=['--crop',','.join(str(proposal['crop'][k]) for k in ['centerX','centerY','width','height'])]
            else:words+=['--aspect-ratio',1.5 if proposal['orientation']=='landscape' else .75]
            record['applied']=run(*words);save()
            record['afterPreview']=run('preview',ref);save()
            print(json.dumps({'reviewRecord':str(path),'workingRef':ref,'before':record['beforePreview']['outputPath'],'after':record['afterPreview']['outputPath']}))
        except BaseException as e:
            record['error']=str(e);record['reviewStatus']='needs-attention';save();raise

if __name__=='__main__':main()
