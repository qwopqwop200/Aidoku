#!/usr/bin/env python3
import argparse,hashlib,json,subprocess,sys,time,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'forced-source-policy'));from run import difference
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,default=ROOT/'build/native-render-parity/late-plate-trim');p.add_argument('--production',action='store_true');a=p.parse_args();o=a.output.resolve();o.mkdir(parents=True,exist_ok=True)
ref=ROOT/'Scripts/native-render-parity/reference-source';manifest=json.loads((ref/'manifest.json').read_text())['files'];oracle=ref/'BrowserOverlayView.swift';digest=hashlib.sha256(oracle.read_bytes()).hexdigest();assert digest==manifest['Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift']
source=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeLatePlateTrim.swift' if a.production else HERE/'NativeLatePlateTrim.swift';shutil.copyfile(HERE/'Probe.swift',o/'main.swift');started=time.monotonic()
subprocess.run(['xcrun','swiftc','-O','-swift-version','6',str(source),str(o/'main.swift'),'-o',str(o/'native-probe')],check=True)
subprocess.run(['python3',str(HERE/'fixtures.py'),str(o/'fixtures.json')],check=True)
subprocess.run(['node',str(HERE/'capture.cjs'),str(oracle),str(o/'fixtures.json'),str(o/'expected.json')],check=True)
subprocess.run([str(o/'native-probe'),str(o/'fixtures.json'),str(o/'actual.json')],check=True)
e=json.loads((o/'expected.json').read_text());n=json.loads((o/'actual.json').read_text());rows=[]
for old,new in zip(e,n):
 d=difference(old,new);rows.append(dict(id=old['id'],exact=d is None,accepted=new['result'] is not None,**({'mismatch':d} if d else {})))
report=dict(passed=all(r['exact'] for r in rows),exact=sum(r['exact'] for r in rows),fixtures=len(rows),accepted=sum(r['accepted'] for r in rows),oracleSHA256=digest,sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest(),comparison='Whole unchanged frozen14350–14596 block; supplied DOM ink and style geometry, actual source band pixels, source calls/page budget, proposed coverage and measured rollback. Platform DOM range measurement separately supplied, not claimed identical.',seconds=time.monotonic()-started,rows=rows)
(o/'report.json').write_text(json.dumps(report,indent=2));print(('PASS' if report['passed'] else 'FAIL')+f" {report['exact']}/{len(rows)}; {report['accepted']} accepted")
if not report['passed']:print(json.dumps([r for r in rows if not r['exact']],indent=2))
raise SystemExit(not report['passed'])
