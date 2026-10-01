import json,subprocess,argparse,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent;S=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';OUT=ROOT/'build/native-render-parity/early-plate-contrast';OUT.mkdir(parents=True,exist_ok=True)
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,default=S/'NativeEarlyPlateContrast.swift');a=p.parse_args()
subprocess.run(['node',str(HERE/'capture.cjs'),str(ROOT),str(OUT/'fixtures.json')],check=True)
subprocess.run(['xcrun','swiftc','-swift-version','6','-strict-concurrency=complete',str(a.source),str(S/'NativePanelGeometry.swift'),str(S/'NativeCSSCoveragePath.swift'),str(S/'NativeTranslationSourceStylePostPolish.swift'),str(HERE/'Probe.swift'),'-o',str(OUT/'probe')],check=True)
subprocess.run([str(OUT/'probe'),str(OUT/'fixtures.json'),str(OUT/'actual.json')],check=True)
f=json.loads((OUT/'fixtures.json').read_text());v=json.loads((OUT/'actual.json').read_text())
def same(a,b):
 if isinstance(a,dict):return isinstance(b,dict) and a.keys()==b.keys() and all(same(a[k],b[k]) for k in a)
 if isinstance(a,list):return isinstance(b,list) and len(a)==len(b) and all(same(x,y) for x,y in zip(a,b))
 if isinstance(a,float) and isinstance(b,(int,float)):return abs(a-b)<1e-12
 return a==b
bad=[x['seed'] for x,y in zip(f,v) if not same(x['expected'],y)]
r={'cases':len(f),'exact':len(f)-len(bad),'mismatches':bad,'decisions':sum(x['decision']is not None for r in v for x in r),'backings':sum(x['backing']is not None for r in v for x in r),'real':[{'case':f[i]['seed'],'output':x} for i,x in enumerate(v) if isinstance(f[i]['seed'],str)],'sourceSHA256':hashlib.sha256(a.source.read_bytes()).hexdigest(),'passed':not bad};(OUT/'report.json').write_text(json.dumps(r,indent=2));print(json.dumps(r));raise SystemExit(bool(bad))
