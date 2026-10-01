#!/usr/bin/env python3
"""Compare Core Text advance adapters with captured actual iOS DOM line ranges."""
import json,os,pathlib,subprocess,time
root=pathlib.Path(__file__).resolve().parents[3]
build=root/'build/native-render-parity/range-metrics';build.mkdir(parents=True,exist_ok=True)
source=os.environ.get('NATIVE_TYPOGRAPHY_SOURCE',str(root/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationTypography.swift'))
start=time.monotonic();subprocess.run(['swiftc','-O',source,str(root/'Scripts/native-render-parity/range-metrics/main.swift'),'-o',str(build/'ranges')],check=True,cwd=root)
compile_seconds=time.monotonic()-start
cases=json.loads((root/'Scripts/native-render-parity/range-metrics/captured-dom-lines.json').read_text())
start=time.monotonic();out=subprocess.run([str(build/'ranges')],input=''.join(json.dumps(c,ensure_ascii=False)+'\n' for c in cases),text=True,capture_output=True,check=True);runtime=time.monotonic()-start
actual=[json.loads(line) for line in out.stdout.splitlines()];assert len(actual)==len(cases)
comparisons=[]
for case,result in zip(cases,actual):
 assert len(case['expected'])==len(result['lines'])
 differences=[[abs(a-b) for a,b in zip(expected,native)] for expected,native in zip(case['expected'],result['lines'])]
 maximum=max(max(row) for row in differences)
 comparisons.append({'id':case['id'],'maximumCoordinateDelta':maximum,'expected':case['expected'],'actual':result})
report={'cases':len(cases),'allLinesWithinOneCSSLayoutUnit':all(c['maximumCoordinateDelta']<=1/64 for c in comparisons),
 'compileSeconds':compile_seconds,'executionSeconds':runtime,'scope':'Actual DOM line rectangles; this compares dimensions and positions, not final pixels. Scalar ranges await separate iOS capture.', 'comparisons':comparisons}
(build/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='comparisons'}))
for c in comparisons:print(c['id'],c['maximumCoordinateDelta'])
if not report['allLinesWithinOneCSSLayoutUnit']:raise SystemExit(1)
