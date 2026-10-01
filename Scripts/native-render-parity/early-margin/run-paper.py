import hashlib,json,subprocess,sys
from pathlib import Path
R=Path(__file__).resolve().parents[3];H=Path(__file__).resolve().parent;O=R/'build/native-render-parity/early-margin-paper';O.mkdir(parents=True,exist_ok=True)
sys.path.insert(0,str(H.parent/'forced-source-policy'));from run import difference
ref=R/'Scripts/native-render-parity/reference-source';manifest=json.loads((ref/'manifest.json').read_text())['files'];hashes={}
for n in ['BrowserOverlayView.swift','BrowserOverlayTypography.swift','BrowserSourcePanelRestoration.swift']:
 sha=hashlib.sha256((ref/n).read_bytes()).hexdigest();assert sha==manifest['Aidoku/Core/Translation/NativeEngine/Overlay/'+n];hashes[n]=sha
source=R/'Aidoku/Core/Translation/NativeEngine/Overlay/NativePartialSourceProof.swift';partial=O/'NativePartialSourceProofHost.swift';partial.write_text(source.read_text().split('extension NativePartialSourceProof {')[0])
subprocess.run(['xcrun','swiftc','-O','-swift-version','6',str(partial),str(R/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeEarlyMarginPaper.swift'),str(H/'PaperProbe.swift'),'-o',str(O/'probe')],check=True)
subprocess.run(['python3',str(H/'paper-fixtures.py'),str(O/'fixtures.json')],check=True);subprocess.run(['node',str(H/'capture-paper.cjs'),str(R),str(O/'expected.json'),str(O/'fixtures.json')],check=True);subprocess.run([str(O/'probe'),str(O/'fixtures.json'),str(O/'actual.json')],check=True)
e=json.loads((O/'expected.json').read_text());a=json.loads((O/'actual.json').read_text());rows=[]
for old,new in zip(e,a):
 d=difference(old,new);rows.append(dict(id=old['id'],exact=d is None,accepted=new['result'] is not None,**({'mismatch':d} if d else {})))
report=dict(passed=all(r['exact'] for r in rows),exact=sum(r['exact'] for r in rows),fixtures=len(rows),positive=sum(r['accepted'] for r in rows),oracleSHA256=hashes,scope='Unchanged frozen7059–7090 crop/read/aux/exclusion/outline/attached/residual/luminance block with supplied enclosed-paper repair descriptors; full production enclosed-paper/finish independently112 exact cases. This proves proposal policy and nullable/failed read budget semantics, not actual font layout.',rows=rows)
(O/'report.json').write_text(json.dumps(report,indent=2));print(('PASS' if report['passed'] else 'FAIL')+f" {report['exact']}/{len(rows)} positive{report['positive']}")
if not report['passed']:print(json.dumps([r for r in rows if not r['exact']],indent=2))
raise SystemExit(not report['passed'])
