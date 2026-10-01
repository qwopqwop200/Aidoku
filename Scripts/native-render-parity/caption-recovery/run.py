import argparse,json,subprocess,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,default=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTypographyCaptionRecovery.swift');a=p.parse_args();OUT=ROOT/'build/native-render-parity/caption-recovery';OUT.mkdir(parents=True,exist_ok=True)
subprocess.run(['node',str(HERE/'capture.cjs'),str(ROOT),str(OUT/'fixtures.json')],check=True)
subprocess.run(['xcrun','swiftc','-swift-version','6','-strict-concurrency=complete',str(a.source),str(HERE/'Probe.swift'),'-o',str(OUT/'probe')],check=True)
subprocess.run([str(OUT/'probe'),str(OUT/'fixtures.json'),str(OUT/'actual.json')],check=True)
f=json.loads((OUT/'fixtures.json').read_text());v=json.loads((OUT/'actual.json').read_text());bad=[{'seed':x['seed'],'keys':[k for k in x['expected'] if x['expected'][k]!=y.get(k)]} for x,y in zip(f,v) if x['expected']!=y]
r={'cases':len(f),'exact':len(f)-len(bad),'mismatches':bad,'reasons':{str(s):sum(x['reason']==s for x in v) for s in [None,'accepted','retained-word-flow','measured-word-flow']},'sourceSHA256':hashlib.sha256(a.source.read_bytes()).hexdigest(),'passed':not bad};(OUT/'report.json').write_text(json.dumps(r,indent=2));print(json.dumps(r));raise SystemExit(bool(bad))
