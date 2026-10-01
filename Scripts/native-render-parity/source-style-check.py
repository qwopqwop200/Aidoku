#!/usr/bin/env python3
"""Compare native source-style policy against the independent frozen JS oracle."""
import json, random, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
REF=Path(__file__).parent/'reference-source'

def function(name):
    for path in REF.glob('*.swift'):
        source=path.read_text(); start=source.find('const '+name+' =')
        if start<0: start=source.find('function '+name+'(')
        if start<0: continue
        
        if name=='aidokuSourceColorLuminance':return source[start:source.index('    const aidokuLuminanceContrast',start)].strip()
        opening=source.index('{',start); depth=0
        for i in range(opening,len(source)):
            if source[i]=='{': depth+=1
            elif source[i]=='}':
                depth-=1
                if depth==0:return source[start:i+2]
    raise ValueError(name)

names=['aidokuStyleGroups','aidokuPageStyleGroups','aidokuInkLab','aidokuInkClusters','aidokuStrokeClusters','aidokuStyleColorClass','aidokuSourceColorLuminance','aidokuLuminanceContrast','aidokuSourceColorContrast','aidokuChromaticOutlineMinimum','aidokuAdjustInkForContrast','aidokuReadableSourceOutline','aidokuSourceStyleOutline','aidokuCaptionPalette','aidokuPanelForeground','aidokuObservedCaptionStyle','aidokuDarkSurfaceSourceOutline','aidokuReleasedCaptionOutline','aidokuReleasedCaptionFill','aidokuSlantedLinear','aidokuRobustSurfaceInk']
script='const aidokuSourceDisplayInk = sample => sample?.providedDisplay || null;\n'+'\n'.join(function(n) for n in names)+'''\nconst jobs=JSON.parse(require('fs').readFileSync(0,'utf8'));
const output=jobs.map(j=>{
if(j.operation==='robust')return aidokuRobustSurfaceInk(j.rgb,j.histogram);
if(j.operation==='releasedOutline')return aidokuReleasedCaptionOutline(j.sample,j.ring,j.font);
if(j.operation==='releasedFill')return aidokuReleasedCaptionFill(j.sample);
if(j.operation==='observed')return aidokuObservedCaptionStyle(j.sample,j.font);
if(j.operation==='dark')return aidokuDarkSurfaceSourceOutline(j.sample,j.ring,j.font,j.certified);
if(j.operation==='caption')return aidokuCaptionPalette({...j.sample,providedDisplay:j.display},j.rgb,j.preserve);
if(j.operation==='class')return aidokuStyleColorClass(j.rgb);
if(j.operation==='ink')return aidokuInkClusters(j.entries).map(g=>({members:g.members.map(({lab,chroma,...e})=>e),rgb:g.rgb}));
if(j.operation==='stroke'){
const result=j.records.filter(r=>r.width>0&&Number.isFinite(r.width)).map(r=>({...r,count:1}));
for(const g of aidokuStrokeClusters(result))for(const r of g.members){r.width=g.width;r.count=g.members.length;}
for(const r of result)if(r.preserved){const m=aidokuChromaticOutlineMinimum(r.fill,r.stroke,r.font),cap=Math.max(r.darkMeasured?2:1,m,Math.min(3.5,r.font*.2));r.width=Math.max(m,Math.min(r.width,cap));}
return result.map(r=>({id:r.id,width:r.width,count:r.count}));}
if(j.operation==='adjust')return aidokuAdjustInkForContrast(j.rgb,rgb=>aidokuLuminanceContrast(aidokuSourceColorLuminance(rgb),...j.range),j.target||4.5);
if(j.operation==='readable')return aidokuReadableSourceOutline(j.sample,j.rgb,j.range,j.font);
return aidokuSourceStyleOutline(j.sample,j.range,j.font);
});process.stdout.write(JSON.stringify(output));'''
rng=random.Random(9003); jobs=[]
for i in range(40):
    entries=[]
    for k in range(12):
        base=[30,40,55] if k<8 else [180,120,55]
        entries.append(dict(id=f'item-{k}',rgb=[max(0,min(255,v+rng.randrange(-18,19))) for v in base],confidence=[.4,.5,.75,.95][k%4]))
    jobs.append(dict(operation='ink',entries=entries))
for i in range(40):
    records=[]
    for k in range(12):
        records.append(dict(id=f's{k}',key=f'k{k%3}',glyph=[10,11,12,14][k%4],font=12+k,width=[0,.5,1.2,4,7][k%5],fill=[240,242,240],stroke=[12,140,180],preserved=k%2==0,darkMeasured=k%3==0))
    jobs.append(dict(operation='stroke',records=records))
for i in range(150):
    rgb=[rng.randrange(256) for _ in range(3)]
    jobs.append(dict(operation='class',rgb=rgb))
    low=rng.random()*.5; high=min(1,low+rng.random()*.5)
    jobs.append(dict(operation='adjust',rgb=rgb,range=[low,high],target=3 if i%2 else 4.5))
    sample=dict(foreground=rgb,stroke=[rng.randrange(256) for _ in range(3)],confidence=dict(stroke=.8,foreground=.9),widthEvidence=dict(relativeToGlyph=.12))
    for op in ('readable','outline'):jobs.append(dict(operation=op,rgb=rgb,sample=sample,range=[low,high],font=8+i%30))
for rgb,stroke,ran in [([20,20,20],[255,255,255],[0,.01]),([255,250,245],[100,25,80],[.8,1]),([230,240,250],[0,0,0],[0,.2])]:
    for op in ('readable','outline'):jobs.append(dict(operation=op,rgb=rgb,sample=dict(foreground=rgb,stroke=stroke,confidence=dict(stroke=.8,foreground=.9)),range=ran,font=20))
for i in range(60):
    sample=dict(background=[30,40,50],surface=dict(color=[120,130,140])) if i%2 else dict(captionBackground=[240,235,230])
    rgb=None if i%5==0 else [17,18,23] if i%5==1 else [255,255,255] if i%5==2 else [90,70,150]
    jobs.append(dict(operation='caption',sample=sample,rgb=rgb,preserve=i%3==0,display=[180,30,90] if i%4==0 else None))
for i in range(60):
    sample=dict(foreground=[12+i,16+i,20+i],stroke=[240,245,250],background=[0,0,0],confidence=dict(stroke=.8,foreground=.9),widthEvidence=dict(relativeToGlyph=.12))
    jobs.append(dict(operation='observed',sample=sample,font=8+i%40))
    sample['sourceInk']=dict(foreground=sample['foreground'],stroke=sample['stroke'],confidence=dict(foreground=.8,stroke=.8))
    ring=dict(kind='outline',core=sample['foreground'],outline=sample['stroke'],hug=1,uniform=.5,exterior=.02,width=.12,reached=.95,boxRing=.1,surface=[0,0,0,1])
    if i%7==0:ring['uniform']=.3
    if i%11==0:ring['exterior']=.04
    jobs.append(dict(operation='dark',sample=sample,ring=ring,font=8+i%40,certified=i%2==0))
for i in range(100):
    sample=dict(foreground=[250,240,245] if i%2 else [12,16,23],stroke=[12,16,23] if i%2 else [250,240,245],background=[12,16,23] if i%2 else [250,240,245],confidence=dict(foreground=[.5,.55,.8][i%3],stroke=[.5,.55,.8][i%3],background=[.4,.5,.8][i%3]))
    ring=dict(kind='outline',hug=[.6,.7,.8][i%3],uniform=[.5,.6,.8][i%3],core=[250,240,245],outline=[12,16,23])
    if i%4==0: sample.pop('stroke')
    if i%5==0: sample['captionBackgroundEvidence']=dict(color=[12,16,23] if i%2 else [250,240,245],coverage=.6)
    if i%7==0: sample['surface']=dict(color=[90,90,90])
    jobs.append(dict(operation='releasedOutline',sample=sample,ring=ring,font=[-1,0,6,12,42.75][i%5]))
    jobs.append(dict(operation='releasedFill',sample=sample))
for ring in [dict(kind='outline',core=[255,255,255],outline=[0,0,0]),dict(kind='outline',hug=None,uniform=.8,core=[255,255,255],outline=[0,0,0])]:
    jobs.append(dict(operation='releasedOutline',sample={},ring=ring,font=12))
for i in range(100):
    histogram=[0]*256
    for _ in range(1000): histogram[rng.choice([0,12,20,24,240,250,255] if i%4==0 else list(range(220,256)) if i%4==1 else list(range(0,30)) if i%4==2 else list(range(90,120)))]+=1
    jobs.append(dict(operation='robust',rgb=[rng.randrange(256) for _ in range(3)],histogram=histogram))
blob=json.dumps(jobs).encode()
web=json.loads(subprocess.check_output(['node','-e',script],input=blob))
native=json.loads(subprocess.check_output([str(ROOT/'build/native-source-style-host/check')],input=blob))
# Floating transcendental operations may differ at one ULP; colors, cohorts, IDs,
# decisions and widths are exact, contrast statistics retain numerical tolerance.
def compare(a,b,path=''):
    if isinstance(a,dict):
        if set(a)!=set(b):return f'{path}: keys {set(a)^set(b)}'
        for k in a:
            failure=compare(a[k],b[k],path+'/'+k)
            if failure:return failure
    elif isinstance(a,list):
        if len(a)!=len(b):return f'{path}: length'
        for k,(x,y) in enumerate(zip(a,b)):
            failure=compare(x,y,path+f'/{k}')
            if failure:return failure
    elif a!=b:
        if (path.endswith('/minimumContrast') or path.endswith('/contrast')) and abs(a-b)<1e-12:return None
        return f'{path}: {a!r} != {b!r}'
failures=[dict(index=i,difference=f) for i,(a,b) in enumerate(zip(web,native)) if (f:=compare(a,b))]
report=dict(cases=len(jobs),failures=failures,exactDecisionAndColorParity=not failures)
(ROOT/'build/native-source-style-host/differential.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2));raise SystemExit(bool(failures))
