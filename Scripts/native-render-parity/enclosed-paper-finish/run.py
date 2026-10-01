import json,subprocess,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent;OUT=ROOT/'build/native-render-parity/enclosed-paper-finish';OUT.mkdir(parents=True,exist_ok=True)
source=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeEnclosedPaperFinish.swift'
subprocess.run(['node',str(HERE/'capture.cjs'),str(ROOT),str(OUT/'fixtures.json')],check=True)
subprocess.run(['xcrun','swiftc','-swift-version','6','-strict-concurrency=complete',str(source),str(HERE/'Probe.swift'),'-o',str(OUT/'probe')],check=True)
subprocess.run([str(OUT/'probe'),str(OUT/'fixtures.json'),str(OUT/'actual.json')],check=True)
f=json.loads((OUT/'fixtures.json').read_text());v=json.loads((OUT/'actual.json').read_text());bad=[x['seed'] for x,y in zip(f,v) if x['expected']!=y]
r={'cases':len(f),'exact':len(f)-len(bad),'mismatches':bad,'positive':sum(x is not None for x in v),'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'passed':not bad};(OUT/'report.json').write_text(json.dumps(r,indent=2));print(json.dumps(r));raise SystemExit(bool(bad))
