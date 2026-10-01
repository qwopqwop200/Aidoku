#!/usr/bin/env python3
"""Compare production residual topology and RGBA speck undo against immutable JS."""
import argparse, hashlib, json, subprocess, sys, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'forced-source-policy'))
from run import difference

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,default=ROOT/'build/native-render-parity/residual-topology');a=p.parse_args();o=a.output.resolve();o.mkdir(parents=True,exist_ok=True)
 ref=ROOT/'Scripts/native-render-parity/reference-source';manifest=json.loads((ref/'manifest.json').read_text())['files'];hashes={}
 for name in ['BrowserOverlayTypography.swift','BrowserOverlayView.swift']:
  digest=hashlib.sha256((ref/name).read_bytes()).hexdigest();assert digest==manifest['Aidoku/Core/Translation/NativeEngine/Overlay/'+name];hashes[name]=digest
 source=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeResidualTopology.swift';started=time.monotonic()
 subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete',str(source),str(HERE/'Probe.swift'),'-o',str(o/'native-probe')],check=True,cwd=ROOT)
 with (o/'oracle.log').open('w') as log:subprocess.run(['node',str(HERE/'capture.cjs'),str(ROOT),str(o/'fixtures.json')],check=True,cwd=ROOT,stdout=log)
 subprocess.run([str(o/'native-probe'),str(o/'fixtures.json'),str(o/'actual.json')],check=True,cwd=ROOT)
 fixtures=json.loads((o/'fixtures.json').read_text());actual=json.loads((o/'actual.json').read_text());assert len(fixtures)==len(actual)
 rows=[];coverage={};mismatches=[]
 for f,observed in zip(fixtures,actual):
  diff=difference(f['expected'],observed);row={'name':f['name'],'policy':f['op'],'exact':diff is None};rows.append(row);c=coverage.setdefault(f['op'],{'fixtures':0,'accepted':0,'rejected':0});c['fixtures']+=1;accepted=observed['accepted'] if isinstance(observed,dict) else bool(observed);c['accepted' if accepted else 'rejected']+=1
  if diff:row['mismatch']=diff;mismatches.append(row)
 assert len(coverage)==6 and all(c['accepted'] and c['rejected'] for c in coverage.values()),coverage
 byname={f['name']:f['expected'] for f in fixtures};assert byname['attached-repeated-protrusions'] is True;assert byname['truthy-two-strict-cell-covers'] is True and byname['truthy-two-strict-cell-cells'] is False
 report={'passed':not mismatches,'fixtures':len(fixtures),'exact':len(fixtures)-len(mismatches),'coverage':coverage,'comparison':'Exact booleans/counts and every RGBA/safe/luminance byte, proof invalidation, surface revisions, restoration undo. DOM canvas putImageData is a counted transport stub only; all native pixel and gate logic is production.','oracleSHA256':hashes,'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'seconds':time.monotonic()-started,'rows':rows,'mismatches':mismatches}
 (o/'report.json').write_text(json.dumps(report,indent=2));(o/'report.md').write_text('| Fixture | Policy | Exact |\n|---|---|---|\n'+'\n'.join(f"| {r['name']} | {r['policy']} | {'PASS' if r['exact'] else 'FAIL'} |" for r in rows)+'\n');print(f"{'PASS' if not mismatches else 'FAIL'}: {report['exact']}/{len(fixtures)} exact; {coverage}")
 if mismatches:print(json.dumps(mismatches,indent=2))
 return bool(mismatches)
if __name__=='__main__':raise SystemExit(main())
