#!/usr/bin/env python3
import argparse,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,default=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeMinimalRestoredPlate.swift');a=p.parse_args()
OUT=ROOT/'build/native-render-parity/minimal-restored-plate';OUT.mkdir(parents=True,exist_ok=True)
subprocess.run(['node',str(HERE/'capture.cjs'),str(ROOT),str(OUT/'fixtures.json')],check=True,cwd=ROOT)
subprocess.run(['xcrun','swiftc','-swift-version','6','-strict-concurrency=complete',str(a.source),str(HERE/'Probe.swift'),'-o',str(OUT/'probe')],check=True,cwd=ROOT)
subprocess.run([str(OUT/'probe'),str(OUT/'fixtures.json'),str(OUT/'actual.json')],check=True,cwd=ROOT)
f=json.loads((OUT/'fixtures.json').read_text());v=json.loads((OUT/'actual.json').read_text());bad=[]
for fixture,actual in zip(f,v):
 if fixture['expected']!=actual:bad.append(fixture['seed'])
r={'cases':len(f),'exact':len(f)-len(bad),'passed':not bad,'positive':sum(x is not None for x in v),'mismatches':bad};(OUT/'report.json').write_text(json.dumps(r,indent=2));print(json.dumps(r));raise SystemExit(0 if not bad else 1)
