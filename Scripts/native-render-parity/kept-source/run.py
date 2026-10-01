#!/usr/bin/env python3
import json, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/kept-source';OUT.mkdir(parents=True,exist_ok=True)
OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';MODEL=ROOT/'build/native-render-parity/restoration-candidate-tests/NativeTranslationModels.swift';SHIM=MODEL.with_name('LayoutHostShims.swift')
subprocess.run(['node',str(HERE/'capture.cjs'),str(ROOT),str(OUT/'fixtures.json')],check=True,cwd=ROOT)
sources=[OVERLAY/(n+'.swift') for n in ['NativeKeptSourceRestoration','NativePanelGeometry','NativeTranslationSourceStylePostPolish']]
subprocess.run(['xcrun','swiftc','-swift-version','6','-strict-concurrency=complete',str(MODEL),str(SHIM),*map(str,sources),str(HERE/'Probe.swift'),'-o',str(OUT/'probe')],check=True,cwd=ROOT)
subprocess.run([str(OUT/'probe'),str(OUT/'fixtures.json'),str(OUT/'actual.json')],check=True,cwd=ROOT)
f=json.loads((OUT/'fixtures.json').read_text());a=json.loads((OUT/'actual.json').read_text());failed=[]
for fixture,actual in zip(f,a):
 if actual['zones']!=fixture['expectedZones'] or actual['selection']!=fixture['expected']:failed.append(fixture['seed'])
r={'cases':len(f),'exact':len(f)-len(failed),'passed':not failed,'positiveSmallOverlaps':sum(bool(v['glyphs']) and bool(v['expected']['pieces']) and not v['expected']['collisions'] for v in f),'mismatches':failed}
(OUT/'report.json').write_text(json.dumps(r,indent=2));print(json.dumps(r));raise SystemExit(0 if not failed else 1)
