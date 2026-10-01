#!/usr/bin/env python3
import json,pathlib,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[3];HERE=pathlib.Path(__file__).resolve().parent;OUT=ROOT/'build/native-render-parity/vertical-content-fit';OUT.mkdir(parents=True,exist_ok=True)
subprocess.run(['python3',str(HERE/'capture.py')],check=True,stdout=subprocess.DEVNULL)
subprocess.run(['swiftc','-O',str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeVerticalContentFit.swift'),str(HERE/'GeometryProbe.swift'),'-o',str(OUT/'geometry-probe')],check=True)
subprocess.run([str(OUT/'geometry-probe'),str(OUT/'dom.json'),str(OUT/'geometry.json')],check=True)
web=json.loads((OUT/'dom.json').read_text());native=json.loads((OUT/'geometry.json').read_text())
failures=[dict(index=i,fixture=w,native=n) for i,(w,n) in enumerate(zip(web,native)) if w['client']+w['scroll']!=n]
report=dict(cases=len(web),exact=not failures,failures=failures,scope='Actual frozen CSS vertical-rl nodes vs native integer scroll/client policy. Actual DOM column count and inline flex extent supplied; CoreText shaping adapter verification remains separate.',activeOverflow=sum(w['client']!=w['scroll'] for w in web))
(OUT/'report.json').write_text(json.dumps(report,indent=2,ensure_ascii=False));print(json.dumps({k:v for k,v in report.items() if k!='failures'}));raise SystemExit(bool(failures))
