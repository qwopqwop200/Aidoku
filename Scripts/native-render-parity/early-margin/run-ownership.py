import hashlib,json,subprocess,sys
from pathlib import Path
R=Path(__file__).resolve().parents[3];H=Path(__file__).resolve().parent;O=R/'build/native-render-parity/early-balloon-ownership';O.mkdir(parents=True,exist_ok=True)
sys.path.insert(0,str(H.parent/'forced-source-policy'));from run import difference
subprocess.run(['xcrun','swiftc','-O','-swift-version','6',str(R/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeEarlyBalloonOwnership.swift'),str(H/'OwnershipProbe.swift'),'-o',str(O/'probe')],check=True)
subprocess.run(['python3',str(H/'ownership-fixtures.py'),str(O/'fixtures.json')],check=True);subprocess.run(['node',str(H/'capture-ownership.cjs'),str(R),str(O/'expected.json'),str(O/'fixtures.json')],check=True);subprocess.run([str(O/'probe'),str(O/'fixtures.json'),str(O/'actual.json')],check=True)
e=json.loads((O/'expected.json').read_text());a=json.loads((O/'actual.json').read_text());bad=[dict(id=o['id'],mismatch=difference(o,n)) for o,n in zip(e,a) if difference(o,n)]
report=dict(passed=not bad,fixtures=len(e),exact=len(e)-len(bad),positive=sum(r['accepted'] for r in a),scope='Unchanged frozen4548–4619 shared owner removal admission with genuine connected/restored/partial/opaque/explicit coverage state. No glyph metrics claim.',mismatches=bad)
(O/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report));raise SystemExit(bool(bad))
