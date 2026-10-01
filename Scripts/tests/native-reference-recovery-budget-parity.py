import json,pathlib,random,subprocess
root=pathlib.Path(__file__).resolve().parents[2]
folder=root/'build/native-reference-budget-proof'
folder.mkdir(parents=True,exist_ok=True)
fixture=root/'Scripts/tests/fixtures/native-reference-recovery-budget'
r=random.Random(16384)
cases=[]
for n in range(96):
    def reference(): return {'length':r.choice([0,1,32,180,511,512,513]),'fontSize':r.choice([None,6,7.99,8,8.5,12]),'paddingIsValid':r.choice([True,True,False])}
    cases.append({'initial':[reference() for _ in range(r.randint(1,70))],'dynamic':[reference() for _ in range(r.randint(0,20))]})
cases += [{'initial':[{'length':512,'fontSize':7,'paddingIsValid':True} for _ in range(40)],'dynamic':[{'length':32,'fontSize':8.5,'paddingIsValid':True}]}]
(folder/'input.json').write_text(json.dumps(cases))
subprocess.run(['swiftc','-O',str(root/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeReferenceRecoveryBudget.swift'),str(fixture/'main.swift'),'-o',str(folder/'probe')],check=True)
subprocess.run([str(folder/'probe'),str(folder/'input.json'),str(folder/'native.json')],check=True)
subprocess.run(['node',str(fixture/'oracle.cjs'),str(folder/'input.json'),str(folder/'frozen.json'),str(root/'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift')],check=True)
a=json.loads((folder/'native.json').read_text());b=json.loads((folder/'frozen.json').read_text())
diffs=[i for i,(x,y) in enumerate(zip(a,b)) if x!=y]
report={'cases':len(cases),'exact':len(cases)-len(diffs),'differences':diffs,'scope':'Original smallTextReference reserve/admission/debit including supplied dynamic refs. Runtime generation of paragraph refs and native font probes excluded.'}
(root/'build/native-render-parity/reference-recovery-budget-policy.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report));assert not diffs
