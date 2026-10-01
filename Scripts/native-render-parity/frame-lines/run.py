#!/usr/bin/env python3
import json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/frame-lines';OUT.mkdir(parents=True,exist_ok=True)
subprocess.run(['node',str(HERE/'capture.cjs'),str(ROOT),str(OUT/'fixtures.json')],check=True)
subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete',str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeSourceFrameLines.swift'),str(HERE/'Probe.swift'),'-o',str(OUT/'probe')],check=True)
subprocess.run([str(OUT/'probe'),str(OUT/'fixtures.json'),str(OUT/'actual.json')],check=True)
f=json.loads((OUT/'fixtures.json').read_text());a=json.loads((OUT/'actual.json').read_text());bad=[]
for i,(fixture,actual) in enumerate(zip(f,a)):
 for key,value in fixture['expected'].items():
  if value!=actual[key]:bad.append({'case':i,'field':key})
r={'cases':len(f),'exact':len(f)-len(set(x['case'] for x in bad)),'passed':not bad,'failures':bad,'positive':sum(x['restored']>0 for x in a)}
(OUT/'report.json').write_text(json.dumps(r,indent=2));print(json.dumps(r));raise SystemExit(bool(bad))
