#!/usr/bin/env python3
"""Frozen display artwork masks, admission/budget and final typography trials."""
import hashlib,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/display-lettering';OUT.mkdir(parents=True,exist_ok=True)
SOURCES=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
# Only remove unrelated enum APIs; pushPull's production implementation is
# compiled verbatim, including the recursive Float32 stores.
slanted=SOURCES/'NativeSlantedInkSafety.swift';s=slanted.read_text()
pull=OUT/'NativeDisplayPushPullTransport.swift'
pull.write_text('import Foundation\nenum NativeSlantedInkSafety {\n'+s[s.index('    static func pushPull('):s.rfind('\n}') ]+'\n}\n')
reports={}; allbad=[]
for kind,capture,probe,sources in [
 ('pixels','capture.cjs','Probe.swift',sorted(SOURCES.glob('NativeDisplayLettering*.swift'))+[pull]),
 ('trial','trial-capture.cjs','TrialProbe.swift',[SOURCES/'NativeDisplayLetteringTrial.swift']),
 ('stage','stage-capture.cjs','StageProbe.swift',[SOURCES/'NativeDisplayLetteringStage.swift'])]:
 fixtures=OUT/(kind+'-fixtures.json');actual=OUT/(kind+'-actual.json');binary=OUT/(kind+'-probe')
 subprocess.run(['node',str(HERE/capture),str(ROOT),str(fixtures)],check=True,cwd=ROOT)
 subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete',*map(str,sources),str(HERE/probe),'-o',str(binary)],check=True,cwd=ROOT)
 subprocess.run([str(binary),str(fixtures),str(actual)],check=True,cwd=ROOT)
 f=json.loads(fixtures.read_text());a=json.loads(actual.read_text());bad=[]
 for v,r in zip(f,a):
  if v['expected']!=r:
   detail={'seed':v['seed']}
   if isinstance(r,dict) and isinstance(v['expected'],dict):
    detail['keys']=[k for k in set(v['expected'])|set(r) if v['expected'].get(k)!=r.get(k)]
    if 'reject' in detail['keys']:detail.update(expected=v['expected'].get('reject'),actual=r.get('reject'))
    if 'output' in detail['keys'] and 'output'in v['expected'] and 'output'in r:detail['byteDiff']=sum(x!=y for x,y in zip(v['expected']['output'],r['output']))
   bad.append(detail)
 reports[kind]={'cases':len(f),'exact':len(f)-len(bad),'passed':not bad,'mismatches':bad}
 (OUT/(kind+'-report.json')).write_text(json.dumps(reports[kind],indent=2));allbad.extend(bad)
reports['passed']=not allbad
reports['sourceSHA256']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(SOURCES.glob('NativeDisplayLettering*.swift'))+[slanted]}
(OUT/'report.json').write_text(json.dumps(reports,indent=2));print(json.dumps(reports));raise SystemExit(0 if not allbad else 1)
