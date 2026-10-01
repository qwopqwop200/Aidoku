import hashlib,json,subprocess,sys
from pathlib import Path
R=Path(__file__).resolve().parents[3];H=Path(__file__).resolve().parent;O=R/'build/native-render-parity/early-margin-trials';O.mkdir(parents=True,exist_ok=True)
sys.path.insert(0,str(H.parent/'forced-source-policy'));from run import difference
ref=R/'Scripts/native-render-parity/reference-source';manifest=json.loads((ref/'manifest.json').read_text())['files'];hashes={}
for n in ['BrowserOverlayView.swift','BrowserOverlayTypography.swift','BrowserSourcePanelRestoration.swift']:
 sha=hashlib.sha256((ref/n).read_bytes()).hexdigest();assert sha==manifest['Aidoku/Core/Translation/NativeEngine/Overlay/'+n];hashes[n]=sha
app=R/'Aidoku/Core/Translation/NativeEngine/Overlay';partial=app/'NativePartialSourceProof.swift';prefix=partial.read_text().split('extension NativePartialSourceProof {')[0];(O/'NativePartialSourceProofHost.swift').write_text(prefix)
sources=[app/'NativeResidualTopology.swift',app/'NativeFinalRestorationTrial.swift',O/'NativePartialSourceProofHost.swift',R/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeEarlyMarginPixels.swift',R/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeEarlyMarginTrial.swift',H/'TrialProbe.swift']
subprocess.run(['xcrun','swiftc','-O','-swift-version','6',*map(str,sources),'-o',str(O/'probe')],check=True)
subprocess.run(['python3',str(H/'trial-fixtures.py'),str(O/'fixtures.json')],check=True);subprocess.run(['node',str(H/'capture-trials.cjs'),str(R),str(O/'expected.json'),str(O/'fixtures.json')],check=True);subprocess.run([str(O/'probe'),str(O/'fixtures.json'),str(O/'actual.json')],check=True)
e=json.loads((O/'expected.json').read_text());a=json.loads((O/'actual.json').read_text());rows=[]
for old,new in zip(e,a):
 d=difference(old,new);rows.append(dict(id=old['id'],exact=d is None,trace=new['trace'],**({'mismatch':d} if d else {})))
report=dict(passed=all(r['exact'] for r in rows),exact=sum(r['exact'] for r in rows),fixtures=len(rows),oracleSHA256=hashes,scope='Entire frozen6717–7176 block executed unchanged with exact source predicates, actual safe-cell gated residual callbacks and supplied independent mode-specific layout acceptance callbacks. This13-fixture phase covers direct trial priority, three-pass partial priority, exact flags/policy rollback, residual refusal/commit/undo and revisions. Paper budget0 deliberately disables enlarged candidate branch; source-position foreground unavailable deliberately disables outlined branch. Separate37 exact pixel fixtures cover group/exterior transport; actual app glyph fit callbacks and positive enlarged-paper orchestration still pending.',rows=rows)
(O/'report.json').write_text(json.dumps(report,indent=2));print(('PASS' if report['passed'] else 'FAIL')+f" {report['exact']}/{len(rows)}")
if not report['passed']:print(json.dumps([r for r in rows if not r['exact']],indent=2))
raise SystemExit(not report['passed'])
