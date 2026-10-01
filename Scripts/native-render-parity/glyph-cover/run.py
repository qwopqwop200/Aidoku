#!/usr/bin/env python3
"""Frozen complete anonymous GlyphCover policy versus actual native Swift, exact bytes."""
import argparse,hashlib,json,subprocess,sys,time,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'forced-source-policy'));from run import difference

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,default=ROOT/'build/native-render-parity/glyph-cover');p.add_argument('--staged',action='store_true');a=p.parse_args();o=a.output.resolve();o.mkdir(parents=True,exist_ok=True)
 ref=ROOT/'Scripts/native-render-parity/reference-source';manifest=json.loads((ref/'manifest.json').read_text())['files'];oracle=ref/'BrowserOverlayView.swift';digest=hashlib.sha256(oracle.read_bytes()).hexdigest();assert digest==manifest['Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift']
 source=HERE/'NativeGlyphCover.swift' if a.staged else ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeGlyphCover.swift';started=time.monotonic();shutil.copyfile(HERE/'Probe.swift',o/'main.swift')
 subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete',str(source),str(o/'main.swift'),'-o',str(o/'native-probe')],check=True,cwd=ROOT)
 subprocess.run(['python3',str(HERE/'fixtures.py'),str(o/'fixtures.json')],check=True,cwd=ROOT)
 subprocess.run(['node',str(HERE/'capture.cjs'),str(oracle),str(o/'fixtures.json'),str(o/'expected.json')],check=True,cwd=ROOT)
 subprocess.run([str(o/'native-probe'),str(o/'fixtures.json'),str(o/'actual.json')],check=True,cwd=ROOT)
 expected=json.loads((o/'expected.json').read_text());actual=json.loads((o/'actual.json').read_text());rows=[]
 for e,n in zip(expected,actual):
  mismatch=difference(e,n);rows.append(dict(name=e['id'],exact=mismatch is None,accepted=n['result'] is not None,rejection=n['rejection'],edge=n['result'] and n['result']['metadata'].get('edge'),fit=n['result'] and n['result']['metadata'].get('fit'),**({'mismatch':mismatch} if mismatch else {})))
 assert len(expected)==len(actual) and any(r['accepted'] and r['fit']=='curve' for r in rows) and any(r['accepted'] and r['edge'] and not r['fit'] for r in rows) and any(r['rejection']=='haze' for r in rows) and any(r['rejection']=='texture' for r in rows)
 report=dict(passed=all(r['exact'] for r in rows),fixtures=len(rows),exact=sum(r['exact'] for r in rows),accepted=sum(r['accepted'] for r in rows),comparison='Full unchanged frozen 14900–15480 orchestration executed with supplied DOM owner geometry and deterministic readSource buffers; every repair RGBA, cover/letter/art mask byte, source crop, styling, metadata, rejection and page budget compared without tolerance. Actual rotated/clipped preflight, gradient diffusion, sharp line, robust curve success, haze and texture refusal. Mock DOM does not claim platform text/pixel resampling parity; those have independent actual WebKit proofs. No source erasure certification inferred.',oracleSHA256=digest,sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest(),seconds=time.monotonic()-started,rows=rows)
 (o/'report.json').write_text(json.dumps(report,indent=2));print(('PASS' if report['passed'] else 'FAIL')+f" {report['exact']}/{report['fixtures']}, {report['accepted']} accepted")
 if not report['passed']:print(json.dumps([r for r in rows if not r['exact']],indent=2))
 return not report['passed']
if __name__=='__main__':raise SystemExit(main())
