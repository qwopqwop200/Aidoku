#!/usr/bin/env python3
"""Compare the real native SAT crop search with frozen browser clearShift."""
import json,math,pathlib,subprocess,time
root=pathlib.Path(__file__).resolve().parents[3]
build=root/'build/native-render-parity/placement-search';build.mkdir(parents=True,exist_ok=True)
start=time.monotonic()
subprocess.run(['swiftc','-O',str(root/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTypographyPlacementSearch.swift'),str(root/'Scripts/native-render-parity/placement-search/main.swift'),'-o',str(build/'placement')],check=True,cwd=root)
compile_seconds=time.monotonic()-start
cases=json.loads(subprocess.check_output(['node','Scripts/native-render-parity/placement-search/oracle.cjs'],cwd=root))
start=time.monotonic();result=subprocess.run([str(build/'placement')],input=''.join(json.dumps(v)+'\n' for v in cases),text=True,capture_output=True,check=True)
runtime=time.monotonic()-start
actual=[json.loads(v) for v in result.stdout.splitlines()];assert len(actual)==len(cases)
def equivalent(a,b):
 if a is None or b is None:return a is b
 return isinstance(a,list) and isinstance(b,list) and len(a)==len(b) and all(math.isclose(x,y,rel_tol=0,abs_tol=1e-10) for x,y in zip(a,b))
failures=[{'id':c['id'],'expected':c['expected'],'actual':a} for c,a in zip(cases,actual) if not equivalent(c['expected'],a)]
report={'cases':len(cases),'passed':len(cases)-len(failures),'failed':len(failures),'compileSeconds':compile_seconds,'executionSeconds':runtime,'failures':failures}
(build/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='failures'}));print(json.dumps(failures[:3]))
if failures:raise SystemExit(1)
