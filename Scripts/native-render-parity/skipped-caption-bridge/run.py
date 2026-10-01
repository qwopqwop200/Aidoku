#!/usr/bin/env python3
"""Compare the literal frozen skipped-caption block with the native helper."""
import json, random, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/skipped-caption-bridge'
OUT.mkdir(parents=True,exist_ok=True)
NODE=r'''
const fs=require('fs'),vm=require('vm'),base=process.argv[1],fixtures=JSON.parse(fs.readFileSync(0,'utf8'));
const source=fs.readFileSync(base+'/BrowserOverlayView.swift','utf8');
const start=source.indexOf('const bridgeNodes=new Map'),end=source.indexOf('      }})();',start)+'      }})();'.length;
const type=fs.readFileSync(base+'/BrowserOverlayTypography.swift','utf8');
const ss=type.indexOf('const aidokuSolidPanelCoverage ='),se=type.indexOf('    };',ss)+'    };'.length;
const output=fixtures.map(f=>{
 const box=a=>({left:a[0],top:a[1],right:a[0]+a[2],bottom:a[1]+a[3],width:a[2],height:a[3]});
 const items=f.sources.map((s,i)=>({id:String(i),sourceFrame:[0,0,1,1],sourceBounds:s.bounds[0],auxiliaryInkRects:s.bounds.slice(1),sourceFontSize:s.sourceFont,sourceVertical:s.vertical}));
 const nodes=f.sources.map((s,i)=>({dataset:{aidokuRegion:String(i),sourceErasurePreserved:s.oversized?'oversized-unrestored':''},style:{fontSize:String(s.font)}}));
 const layer={dataset:{captionUnionClipped:f.clipped?'true':'false',panelCoverage:JSON.stringify(f.coverage||[])},style:{},getBoundingClientRect:()=>box(f.layer)};
 const root={querySelectorAll:()=>nodes};
 const context=vm.createContext({root,items,cleanupImageGeometry:{frame:[0,0,1,1]},typographyInkFrames:new Map(items.map((s,i)=>[s,{pad:f.sources[i].priorPadding||0}])),
 finalInks:new Map(f.inks.map((r,i)=>[String(i),r])),skippedCaptions:[{node:nodes[0],owned:[layer],panel:layer}],backings:[],sourceRect:()=>true,CSS:{supports:()=>true}});
 vm.runInContext(type.slice(ss,se)+'\n'+source.slice(start,end),context);
 return {name:f.name,coverage:layer.dataset.captionUnionClipped==='true'?JSON.parse(layer.dataset.panelCoverage):[],bridge:layer.dataset.sourceBridgeClipped==='true'};
});process.stdout.write(JSON.stringify(output));
'''
rng=random.Random(7849)
fixtures=[]
for i in range(100):
    sources=[]
    for j in range(rng.randrange(1,8)):
        sources.append({'bounds':[[rng.uniform(-10,100),rng.uniform(-10,80),rng.uniform(1,30),rng.uniform(1,25)] for _ in range(rng.randrange(1,4))],
            'font':rng.choice([5,8.5,10,22]),'sourceFont':rng.choice([3,12,24]),'priorPadding':rng.choice([0,3,6]),'vertical':rng.choice([False,True]),'oversized':False})
    fixtures.append({'name':f'matrix-{i}','sources':sources,'inks':[[rng.uniform(0,100),rng.uniform(0,80),rng.uniform(1,20),rng.uniform(1,15)]],
        'layer':[0,0,100,80],'clipped':i%3==0,'coverage':[[5,5,20,30],[60,20,25,40]]})
for count in [0,512,513]:
    fixtures.append({'name':f'cap-{count}','sources':[{'bounds':[[200,200,10,10]],'font':5}],
        'inks':[[1,1,2,2]]*count,'layer':[0,0,100,80]})
(OUT/'fixtures.json').write_text(json.dumps(fixtures))
source=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
names=['NativeTranslationPixelKernels','NativeSourceColorSampler','NativeCSSCoveragePath', 'NativeTranslationSourceStylePostPolish','NativePanelGeometry','NativeSkippedCaptionBridge']
lib=ROOT/'build/native-overlay-kernels-host/libAidokuOverlayKernels.a'
subprocess.run(['swiftc','-swift-version','6','-O','-I',str(ROOT/'Scripts/overlay-kernels/native'),*[str(source/(n+'.swift')) for n in names],str(HERE/'main.swift'),str(lib),'-o',str(OUT/'native')],check=True)
subprocess.run([str(OUT/'native'),str(OUT/'fixtures.json'),str(OUT/'native.json')],check=True)
web=json.loads(subprocess.check_output(['node','-e',NODE,str(ROOT/'Scripts/native-render-parity/reference-source')],input=json.dumps(fixtures).encode()))
native=json.loads((OUT/'native.json').read_text());(OUT/'web.json').write_text(json.dumps(web))
def equal(a,b):
    if isinstance(a,(int,float)) and not isinstance(a,bool) and isinstance(b,(int,float)) and not isinstance(b,bool):return abs(a-b)<1e-9
    if type(a)!=type(b):return False
    if isinstance(a,list):return len(a)==len(b) and all(equal(x,y) for x,y in zip(a,b))
    if isinstance(a,dict):return a.keys()==b.keys() and all(equal(a[k],b[k]) for k in a)
    return a==b
fail=[a['name'] for a,b in zip(native,web) if not equal(a,b)]
report={'fixtures':len(fixtures),'passed':len(fixtures)-len(fail),'failures':fail,'scope':'Literal frozen7849–7892 plus exact solidPanelCoverage; source margins, final inks, prior clipping and pre-merge cap'}
(OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report));raise SystemExit(bool(fail))
