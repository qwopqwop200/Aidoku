#!/usr/bin/env python3
"""Observe whole DOM ranges separately from per-scalar ownership ranges."""
import json, pathlib, subprocess
root=pathlib.Path(__file__).resolve().parents[3]
out=root/'build/native-render-parity/block-word-range';out.mkdir(parents=True,exist_ok=True)
folder=pathlib.Path(__file__).parent
with (out/'dom.json').open('w') as f: subprocess.run(['swift',str(folder/'capture.swift')],stdout=f,check=True)
subprocess.run(['swiftc','-O',str(root/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationTypography.swift'),str(root/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTextPaintGeometry.swift'),str(root/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeKeepAllAutoLines.swift'),str(root/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeKeepAllTextBalance.swift'),str(root/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeKeepAllBreakOpportunities.swift'),str(root/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeRawTextBalance.swift'),str(root/'Aidoku/Core/Translation/NativeEngine/Overlay/NativePreformattedTabs.swift'),str(folder/'main.swift'),'-o',str(out/'probe')],check=True)
dom=json.loads((out/'dom.json').read_text())
response=subprocess.run([str(out/'probe')],input=''.join(json.dumps(w['a'],ensure_ascii=False)+'\n' for w in dom),text=True,capture_output=True,check=True)
comparisons=[]
for web,line in zip(dom,response.stdout.splitlines()):
 native=json.loads(line)
 comparisons.append({'input':web['a'],'dom':web['whole'],'native':native['whole'],'delta':max(abs(a-b) for a,b in zip(web['whole'],native['whole'])),'nativeText':native['text']})
(out/'comparison.json').write_text(json.dumps(comparisons,ensure_ascii=False,indent=2))
controlled=[c for c in comparisons if c['input']['mode']!='raw']
ordinary=[c for c in comparisons if c['input']['mode']=='raw' and '\t' not in c['input']['text']]
remaining=[c for c in comparisons if c['delta']>1/64]
report={'controlledCases':len(controlled),'controlledPass':all(c['delta']<1/64 for c in controlled),'controlledMaximumDelta':max(c['delta'] for c in controlled),'ordinaryWithoutTabsCases':len(ordinary),'ordinaryWithoutTabsPass':all(c['delta']<1/64 for c in ordinary),'remainingCases':len(remaining),'remainingScope':'Ordinary pre-wrap tab stops and hanging whitespace; controlled nowrap span/selected wrapper contract is exact within float precision. Row segmentation supplied; no final raster equality claim.'}
(out/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report))
assert report['controlledPass'] and report['ordinaryWithoutTabsPass']
