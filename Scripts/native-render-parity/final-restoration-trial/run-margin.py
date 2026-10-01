#!/usr/bin/env python3
"""Exact immutable JS late trial orchestration versus actual native policies."""
import argparse,hashlib,json,subprocess,sys,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'forced-source-policy'));from run import difference

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,default=ROOT/'build/native-render-parity/early-margin-trial');a=p.parse_args();o=a.output.resolve();o.mkdir(parents=True,exist_ok=True)
 ref=ROOT/'Scripts/native-render-parity/reference-source';manifest=json.loads((ref/'manifest.json').read_text())['files'];hashes={}
 for name in ['BrowserOverlayView.swift','BrowserOverlayTypography.swift']:
  digest=hashlib.sha256((ref/name).read_bytes()).hexdigest();assert digest==manifest['Aidoku/Core/Translation/NativeEngine/Overlay/'+name];hashes[name]=digest
 sources=[ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'/name for name in ['NativeResidualTopology.swift','NativeFinalRestorationTrial.swift']];started=time.monotonic()
 subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete',*map(str,sources),str(HERE/'MarginProbe.swift'),'-o',str(o/'native-probe')],check=True,cwd=ROOT)
 with (o/'oracle.log').open('w') as log:subprocess.run(['node',str(HERE/'margin-capture.cjs'),str(ROOT),str(o/'fixtures.json')],check=True,cwd=ROOT,stdout=log)
 subprocess.run([str(o/'native-probe'),str(o/'fixtures.json'),str(o/'actual.json')],check=True,cwd=ROOT)
 fixtures=json.loads((o/'fixtures.json').read_text());actual=json.loads((o/'actual.json').read_text());assert len(fixtures)==len(actual)
 rows=[];mismatches=[];coverage={}
 for f,v in zip(fixtures,actual):
  mismatch=difference(f['expected'],v);row={'name':f['name'],'policy':'group' if f['group'] else 'initial','exact':mismatch is None,'accepted':v['accepted']};rows.append(row);c=coverage.setdefault(row['policy'],{'fixtures':0,'accepted':0,'rejected':0});c['fixtures']+=1;c['accepted' if row['accepted'] else 'rejected']+=1
  if mismatch:row['mismatch']=mismatch;mismatches.append(row)
 assert len(coverage)==2 and all(c['accepted'] and c['rejected'] for c in coverage.values())
 report={'passed':not mismatches,'fixtures':len(fixtures),'exact':len(fixtures)-len(mismatches),'coverage':coverage,'comparison':'Exact coverage geometry, local regions/core/glyph sizes and initial/group certification. Actual frozen admission blocks with unchanged mask topology; geometry instrumentation records existing values only.','oracleSHA256':hashes,'sourceSHA256':{s.name:hashlib.sha256(s.read_bytes()).hexdigest() for s in sources},'seconds':time.monotonic()-started,'rows':rows,'mismatches':mismatches}
 (o/'report.json').write_text(json.dumps(report,indent=2));(o/'report.md').write_text('| Fixture | Exact | Accepted |\n|---|---|---|\n'+'\n'.join(f"| {r['name']} | {'PASS' if r['exact'] else 'FAIL'} | {r['accepted']} |" for r in rows)+'\n');print(f"{'PASS' if not mismatches else 'FAIL'} {report['exact']}/{len(fixtures)}; {coverage}")
 if mismatches:print(json.dumps(mismatches,indent=2))
 return bool(mismatches)
if __name__=='__main__':raise SystemExit(main())
