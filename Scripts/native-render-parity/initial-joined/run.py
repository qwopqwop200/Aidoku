#!/usr/bin/env python3
import json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/initial-joined';OUT.mkdir(parents=True,exist_ok=True)
subprocess.run(['node',str(HERE/'capture.cjs'),str(ROOT),str(OUT/'fixtures.json')],check=True)
subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete',str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeInitialJoinedUnit.swift'),str(HERE/'Probe.swift'),'-o',str(OUT/'probe')],check=True)
subprocess.run([str(OUT/'probe'),str(OUT/'fixtures.json'),str(OUT/'actual.json')],check=True)
f=json.loads((OUT/'fixtures.json').read_text());a=json.loads((OUT/'actual.json').read_text());bad=[]
assert len(f)==len(a)
for i,(fixture,actual) in enumerate(zip(f,a)):
 if fixture['expected']!=actual:bad.append({'case':i,'label':fixture['label'],'expected':fixture['expected'],'actual':actual})
r={'cases':len(f),'exact':len(f)-len(bad),'accepted':sum(any(x['planned'] is not None for x in c) for c in a),'passed':not bad,'failures':bad}
(OUT/'report.json').write_text(json.dumps(r,indent=2));print(json.dumps(r));raise SystemExit(bool(bad))
