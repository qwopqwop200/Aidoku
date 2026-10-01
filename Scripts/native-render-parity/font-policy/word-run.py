#!/usr/bin/env python3
"""Compare frozen wordLines dispatch with identical native font width inputs."""
import json,pathlib,subprocess,time
ROOT=pathlib.Path(__file__).resolve().parents[3]
BUILD=ROOT/'build/native-render-parity/font-policy'
# Compile the shared policy driver and run its cluster regressions first.
subprocess.run(['python3','Scripts/native-render-parity/font-policy/run.py'],cwd=ROOT,check=True)
cases=json.loads(subprocess.check_output(['node','Scripts/native-render-parity/font-policy/word-oracle.cjs','generate'],cwd=ROOT))
start=time.monotonic()
result=subprocess.run([str(BUILD/'policy')],input='\n'.join(json.dumps(c,ensure_ascii=False) for c in cases)+'\n',text=True,capture_output=True,check=True)
actual=[json.loads(line) for line in result.stdout.splitlines()]
pairs=[{'input':c['args'][0],'widths':a['widths']} for c,a in zip(cases,actual)]
expected=json.loads(subprocess.check_output(['node','Scripts/native-render-parity/font-policy/word-oracle.cjs'],cwd=ROOT,input=json.dumps(pairs,ensure_ascii=False).encode()))
failures=[{'input':c['args'][0],'expected':e,'actual':a['actual']} for c,a,e in zip(cases,actual,expected) if a['actual']!=e]
report={'cases':len(cases),'passed':len(cases)-len(failures),'failed':len(failures),'executionSeconds':time.monotonic()-start,'scope':'Frozen context-sensitive wordLines with identical native whole-line/code-point advance inputs, 0/1/2 quote modes, 3–12 em, composed/decomposed Hangul.','failures':failures}
(BUILD/'word-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps({k:v for k,v in report.items() if k!='failures'},ensure_ascii=False))
if failures:
 print(json.dumps(failures[:4],ensure_ascii=False));raise SystemExit(1)
