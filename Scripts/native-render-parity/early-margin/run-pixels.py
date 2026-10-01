import hashlib,json,shutil,subprocess,sys
from pathlib import Path
R=Path(__file__).resolve().parents[3];H=Path(__file__).resolve().parent;O=R/'build/native-render-parity/early-margin-pixels';O.mkdir(parents=True,exist_ok=True)
sys.path.insert(0,str(H.parent/'forced-source-policy'));from run import difference
ref=R/'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift';manifest=json.loads((ref.parent/'manifest.json').read_text())['files'];sha=hashlib.sha256(ref.read_bytes()).hexdigest();assert sha==manifest['Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift']
shutil.copy(H/'Probe.swift',O/'main.swift');subprocess.run(['xcrun','swiftc','-O','-swift-version','6',str(R/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeEarlyMarginPixels.swift'),str(O/'main.swift'),'-o',str(O/'probe')],check=True)
subprocess.run(['python3',str(H/'fixtures.py'),str(O/'fixtures.json')],check=True);subprocess.run(['node',str(H/'capture.cjs'),str(ref),str(O/'fixtures.json'),str(O/'expected.json')],check=True);subprocess.run([str(O/'probe'),str(O/'fixtures.json'),str(O/'actual.json')],check=True)
e=json.loads((O/'expected.json').read_text());a=json.loads((O/'actual.json').read_text());rows=[]
for old,new in zip(e,a):
 d=difference(old,new);rows.append(dict(id=old['id'],exact=d is None,accepted=new['result'] is not None,**({'mismatch':d} if d else {})))
report=dict(passed=all(r['exact'] for r in rows),exact=sum(r['exact'] for r in rows),fixtures=len(rows),accepted=sum(r['accepted'] for r in rows),oracleSHA256=sha,scope='Exact frozen6736–6792 exterior source helper and6847–6911 donor proof transport; actual output safe/luminance/budget/cache/revision. Downstream source classification predicates supplied separately and not counted as full EarlyMargin orchestration.',rows=rows)
(O/'report.json').write_text(json.dumps(report,indent=2));print(('PASS' if report['passed'] else 'FAIL')+f" {report['exact']}/{len(rows)}, {report['accepted']} accepted")
if not report['passed']:print(json.dumps([r for r in rows if not r['exact']],indent=2))
raise SystemExit(not report['passed'])
