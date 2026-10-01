#!/usr/bin/env python3
"""Exact geometry outputs against the immutable pre-port browser helper source."""
import json
import random
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).parent
OUT = ROOT / 'build/native-render-parity/panel-geometry'
OUT.mkdir(parents=True, exist_ok=True)
NODE = r'''
const fs=require('fs'),s=fs.readFileSync(process.argv[1],'utf8');
const solid=s.slice(s.indexOf('    const aidokuSolidPanelCoverage ='),s.indexOf('    const aidokuSolidPanelCoverage =')+s.slice(s.indexOf('    const aidokuSolidPanelCoverage =')).indexOf('\n    };')+7);
const start=s.indexOf('    const aidokuCompactPanel ='),end=s.indexOf('    // Page area owned by source lettering',start);
const v=fs.readFileSync(process.argv[2],'utf8'),finalStart=v.indexOf('        let shift=aidokuSourceAnchorShift(ink,source,plate,obstacles);'),finalEnd=v.indexOf('        if(!shift)continue;',finalStart);
const rect=r=>({left:r[0],top:r[1],right:r[0]+r[2],bottom:r[1]+r[3],width:r[2],height:r[3]});
const final=new Function('j',solid+s.slice(start,end)+`const {ink,source,rects:obstacles,panel:plate}=j;const caption={ownFootprint:j.home?{left:j.home[0],top:j.home[1],right:j.home[0]+j.home[2],bottom:j.home[1]+j.home[3]}:null};const node={dataset:{}};const item={sourceFontSize:j.sourceFont,text:'X'.repeat(j.characters)};`+v.slice(finalStart,finalEnd)+'return shift;');
const packingStart=v.indexOf('              const sx=source[0]+source[2]/2,sy=source[1]+source[3]/2;'),packingEnd=v.indexOf('              if(distance>oldDistance+tolerance)return false;',packingStart)+'              if(distance>oldDistance+tolerance)return false;'.length;
let packing=v.slice(packingStart,packingEnd).replace(/              const obstacles=.*?;\n/,'').replace('              const ink=[r.left,r.top,r.width,r.height];','');
const admission=new Function('j',solid+s.slice(start,end)+`const {ink,source,rects:obstacles,original:originalInk}=j;const r={left:ink[0],top:ink[1],width:ink[2],height:ink[3]},box={left:j.panel[0],top:j.panel[1],right:j.panel[0]+j.panel[2],bottom:j.panel[1]+j.panel[3]};`+packing+'return true;');
const run=new Function('jobs','final','admission',solid+s.slice(start,end)+`
return jobs.map(j=>{switch(j.op){
case 'solid':return aidokuSolidPanelCoverage(j.rects);
case 'compact':return aidokuCompactPanel(j.panel,j.ink,j.required,j.rects,j.pad);
case 'visible':return aidokuVisiblePanelColors(j.ink,j.layers,j.fallback);
case 'backing':return aidokuTextBackingRect(j.ink,j.panel,j.rects);
case 'needs':return aidokuNeedsTextBacking(j.ink,j.owner,j.layers.map(p=>({...p,color:p.color.join(',')})));
case 'keeps':return aidokuTextBackingKeepsContrast(j.ink,j.owner,j.layers,c=>c[0]);
case 'anchor':return aidokuSourceAnchorShift(j.ink,j.source,j.panel,j.rects,j.leavesOverlap);
case 'finalAnchor':return final(j);
case 'packing':return admission(j);
case 'subtract':return aidokuSubtractRects(j.rects.map(r=>({left:r[0],top:r[1],right:r[0]+r[2],bottom:r[1]+r[3]})),{left:j.cut[0],top:j.cut[1],right:j.cut[0]+j.cut[2],bottom:j.cut[1]+j.cut[3]}).map(r=>[r.left,r.top,r.right-r.left,r.bottom-r.top]);
}});`);
process.stdout.write(JSON.stringify(run(JSON.parse(fs.readFileSync(0,'utf8')),final,admission)));
'''
rng = random.Random(847291)
jobs = []
for i in range(128):
    # Binary fractions give exact cross-language CGFloat/Number inputs.
    ink = [rng.randrange(4, 70)/4, rng.randrange(4, 70)/4, rng.randrange(4, 70)/4, rng.randrange(4, 70)/4]
    panel = [0, 0, 64, 64]
    rects = [[rng.randrange(-20, 200)/4, rng.randrange(-20, 200)/4, rng.randrange(1, 100)/4, rng.randrange(1, 100)/4] for _ in range(i % 5)]
    colors = [[1+i % 7, 20, 30], [3, 20, 30], [1+i % 7, 20, 30]]
    layers = [dict(rect=r, coverage=[r], color=colors[k % 3]) for k, r in enumerate(rects)]
    base = dict(ink=ink, panel=panel, rects=rects)
    jobs.extend([dict(op='solid', rects=rects), dict(op='subtract', rects=rects, cut=ink),
                 dict(op='compact', **base, required=rects[:1], pad=(i % 9)/4),
                 dict(op='backing', **base), dict(op='visible', ink=ink, layers=layers, fallback=[255, 255, 255]),
                 dict(op='needs', ink=ink if i % 13 else None, owner=i % 6-1, layers=layers),
                 dict(op='keeps', ink=ink if i % 13 else None, owner=i % 6-1, layers=layers),
                 dict(op='anchor', **base, source=[36, 36, 12, 12], leavesOverlap=i % 2 == 0)])
    jobs.extend([dict(op='finalAnchor', **base, source=[36,36,12,12],home=[32,32,24,24] if i%2 else None,sourceFont=12,characters=3+i%6),
                 dict(op='packing', **base, source=[36,36,12,12],original=[36,36,12,12])])
# Active collision, optically negligible movement, fractional snap, padding
# fallback, paint occlusion, retained tiny edge, and invalid/bounded contracts.
jobs.extend([
    dict(op='solid', rects=[[0, 0, 0, 10]]), dict(op='solid', rects=[[0, 0, 1, 1]] * 513),
    dict(op='anchor', ink=[8, 8, 8, 8], source=[40, 40, 8, 8], panel=[0, 0, 64, 64], rects=[], leavesOverlap=False),
    dict(op='anchor', ink=[8, 8, 8, 8], source=[40, 40, 8, 8], panel=[0, 0, 64, 64], rects=[[24, 0, 4, 64]], leavesOverlap=False),
    dict(op='anchor', ink=[8.013, 8.009, 8, 8], source=[40.033, 40.041, 8, 8], panel=[0, 0, 64, 64], rects=[], leavesOverlap=False),
    dict(op='backing', ink=[8, 8, 8, 8], panel=[0, 0, 32, 32], rects=[[17, 8, 2, 8]]),
    dict(op='compact', panel=[0, 0, 16, 16], ink=[3.2, 3.2, 9.6, 9.6], required=[], rects=[], pad=2.5),
    dict(op='visible', ink=[0, 0, 16, 16], layers=[dict(rect=[0, 0, 16, 16], coverage=[[0, 0, 16, 16]], color=[8, 8, 8]),dict(rect=[0, 0, 16, 16],coverage=[[0, 0, 8, 16]],color=[255, 255, 255])], fallback=[128, 128, 128]),
])
subprocess.run(['swiftc', '-O', str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeCSSCoveragePath.swift'),str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationSourceStylePostPolish.swift'), str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativePanelGeometry.swift'), str(HERE/'PanelGeometryMain.swift'), '-o', str(OUT/'check')], check=True)
blob = json.dumps(jobs).encode()
web = json.loads(subprocess.check_output(['node', '-e', NODE, str(HERE/'reference-source/BrowserOverlayTypography.swift'),str(HERE/'reference-source/BrowserOverlayView.swift')], input=blob))
native = json.loads(subprocess.check_output([str(OUT/'check')], input=blob))
failures = [dict(index=i, fixture=jobs[i], web=a, native=b) for i, (a, b) in enumerate(zip(web, native)) if a != b]
stats = {op: dict(cases=sum(j['op'] == op for j in jobs), active=sum(j['op'] == op and v not in (None, False, []) for j, v in zip(jobs, native))) for op in sorted({j['op'] for j in jobs})}
report = dict(cases=len(jobs), exact=not failures, failed=len(failures), operations=stats, failures=failures)
(OUT/'differential.json').write_text(json.dumps(report, indent=2))
print(json.dumps({k:v for k,v in report.items() if k != 'failures'}))
raise SystemExit(bool(failures))
