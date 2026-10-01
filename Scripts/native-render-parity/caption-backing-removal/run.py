#!/usr/bin/env python3
"""Frozen full caption polish versus staged native redundant-backing transport."""
import copy
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
OUT = ROOT / 'build/native-render-parity/caption-backing-removal'
OUT.mkdir(parents=True, exist_ok=True)
OVERLAY = ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay'
REF = HERE.parent / 'reference-source/BrowserOverlayTypography.swift'
# Preserve the existing frozen DOM oracle; extend only its backing inventory
# and ordinary computed-style transport. The frozen helper itself is unedited.
old = (HERE.parent / 'caption-panel-check.py').read_text()
node = old.split("NODE=r'''", 1)[1].split("'''", 1)[0]
node = node.replace('process.argv[1]', 'process.argv[2]')
node = node.replace("transform:'none',scale:'none'", "transform:n.style.transform||'none',scale:'none'")
node = node.replace('const nodes=[],panels=[],items=[];', 'const nodes=[],panels=[],backings=[],items=[];')
node = node.replace("if(selector.includes('source-readability-backing'))return [];", "if(selector.includes('source-readability-backing'))return backings.filter(n=>!n.removed);")
node = node.replace("n.style.fontSize=e.font+'px';nodes.push(n);", "n.style.fontSize=e.font+'px';nodes.push(n);if(e.isFlat===false)n.style.transform='scaleX(.9)';")
node = node.replace('panels.push(q);}', "if(p.isFlat===false)q.style.transform='rotate(.1rad)';panels.push(q);}")
node = node.replace(' const f=e.frame,local=', " for(const p of e.backings||[]){const q=node(p.frame,'source-readability-backing',e.id);q.parentElement=root;q.style.backgroundColor=`rgba(${p.color.join(',')},1)`;q.style.clipPath='inset(10%)';backings.push(q);}\n const f=e.frame,local=")
node = node.replace('sourceTextOnly:false,rotation:0,vertical:false', 'sourceTextOnly:e.sourceTextOnly||false,rotation:e.rotation||0,vertical:e.vertical||false')
node = node.replace("wrappingScript:'korean'", "wrappingScript:e.wrappingScript||'korean'")
node = node.replace("coverage:JSON.parse(p.dataset.panelCoverage)}))}));", "coverage:JSON.parse(p.dataset.panelCoverage)})),backings:backings.filter(p=>!p.removed&&p.dataset.aidokuRegion===n.dataset.aidokuRegion).map(p=>[parseFloat(p.style.left),parseFloat(p.style.top),parseFloat(p.style.width),parseFloat(p.style.height)])}));")
(OUT / 'oracle.cjs').write_text(node)

# Extract actual storage types verbatim. No geometry or policy implementation
# is replaced by a host stand-in.
style = (OVERLAY / 'NativeTranslationSourceStylePostPolish.swift').read_text()
panel = re.search(r'    struct Panel \{[\s\S]*?\n    }', style).group()
geometry = (OVERLAY / 'NativePanelGeometry.swift').read_text()
backing = re.search(r'    struct Backing \{[^\n]*}', geometry).group()
(OUT / 'Storage.swift').write_text('import Foundation\nimport CoreGraphics\nenum NativeTranslationSourceStylePostPolish {\n' + panel + '\n}\nenum NativePanelGeometry {\n' + backing + '\n}\n')
main = (HERE.parent / 'CaptionPanelMain.swift').read_text()
main = main.replace('value.sourceErasure =', 'value.isFlat = p["isFlat"] as? Bool ?? true; value.captionUnionClipped = p["clipped"] as? Bool ?? false; value.sourceErasure =')
main = main.replace('return NativeTranslationCaptionPanelPolish.Entry', 'var entry = NativeTranslationCaptionPanelPolish.Entry')
main = main.replace('sourceTextOnly: false, rotation: 0,\n                    vertical: false', 'sourceTextOnly: v["sourceTextOnly"] as? Bool ?? false, rotation: v["rotation"] as? Double ?? 0,\n                    vertical: v["vertical"] as? Bool ?? false')
main = main.replace('wrappingScript: "korean"', 'wrappingScript: v["wrappingScript"] as? String ?? "korean"')
main = main.replace('ink: rect(v["ink"]!), panels: panels)', '''ink: rect(v["ink"]!), panels: panels)
                entry.isFlat = v["isFlat"] as? Bool ?? true
                entry.backings = (v["backings"] as? [[String:Any]] ?? []).map { b in
                    .init(frame:rect(b["frame"]!), coverage:(b["coverage"] as! [[Double]]).map(rect), color:b["color"] as! [Double])
                }
                return entry''')
main = main.replace('"coverage": p.coverage.map(array)] }]', '"coverage": p.coverage.map(array)] }, "backings":e.backings.map { array($0.frame) }]')
(OUT / 'Main.swift').write_text(main)
subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete', str(OVERLAY/'NativeCSSCoveragePath.swift'), str(OUT/'Storage.swift'), str(HERE/'NativeTranslationCaptionPanelPolish.swift'), str(OUT/'Main.swift'), '-o', str(OUT/'check')], check=True, cwd=ROOT)

def entry():
    return dict(id='2', font=7, frame=[0,0,390,700], ink=[241.921875,265.46875,17.921875,50], sources=[[242.406015,237.26291,13.2,109.]], panels=[dict(rect=[238.890625,233.765625,24,115.546875],background=[58,72,68],coverage=[[238.890625,233.765625,24,115.546875]])], backings=[dict(frame=[238.890625,233.765625,24,115.546875],color=[58,72,68],coverage=[[239.921875,263.46875,21.921875,54]])])
jobs=[]
def add(name, entries, **kwargs): jobs.append(dict(name=name,entries=entries,kept=[],**kwargs))
add('same-color-full-owner-removes', [entry()])
e=entry(); e['backings'][0]['color']=[58,72,69]; add('different-color-retains', [e])
e=entry(); e['backings'][0]['frame'][0]-=.251; add('full-box-outside-even-coverage-inside-retains', [e])
e=entry(); e['backings'][0]['frame'][0]-=.25; e['backings'][0]['frame'][2]+=.5; add('exact-quarter-tolerance-removes', [e])
e=entry(); e['panels'][0]['isFlat']=False; add('transformed-owner-retains', [e])
e=entry(); e['panels'][0]['clipped']=True; add('merge-clears-complete-caption-clip-then-removes', [e])
e=entry(); e['panels'][0]['clipped']=True;e['panels'][0]['coverage']=[[240,240,5,5]]; add('uncertified-clip-retains', [e])
for key,value in [('sourceTextOnly',True),('rotation',.1),('vertical',True),('wrappingScript','word'),('isFlat',False)]:
    e=entry();e[key]=value;add('removal-independent-of-node-eligibility-'+key,[e])
e=entry();add('nonopaque-stage-leaves-clone',[e],opacity=.5)
e=entry();e['panels'].append(copy.deepcopy(e['panels'][0]));e['panels'][1]['background']=[100,100,100];add('multiple-unmerged-owner-retains',[e])
# Neighbor spacing narrows the final owner so that it no longer contains the
# old clone. Removal must therefore run before spacing, not on final records.
e=entry();other=entry();other['id']='3';other['ink']=[264,265,15,50];other['sources']=[[264,237,15,109]];other['panels'][0]['rect']=[259,233.765625,25,115.546875];other['panels'][0]['coverage']=[other['panels'][0]['rect']];other['backings']=[]
add('removes-before-neighbor-spacing-narrows-owner',[e,other])
blob=json.dumps(jobs).encode()
web=json.loads(subprocess.check_output(['node',str(OUT/'oracle.cjs'),str(REF)],input=blob))
native=json.loads(subprocess.check_output([str(OUT/'check')],input=blob))
failures=[dict(name=j['name'],web=a,native=b) for j,a,b in zip(jobs,web,native) if a!=b]
report=dict(cases=len(jobs),passed=len(jobs)-len(failures),failures=failures,results=[dict(name=j['name'],output=v) for j,v in zip(jobs,native)],sourceHashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [REF,HERE/'NativeTranslationCaptionPanelPolish.swift',OUT/'Storage.swift',OUT/'Main.swift']})
(OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k in ['cases','passed','failures']}))
raise SystemExit(bool(failures))
