#!/usr/bin/env python3
"""Frozen-JS crop/probe admission versus production native helper.

Native-size nonuniform pixels and uniformly scaled paper verify geometry,
punctuation ownership and budgets. Actual nonuniform Canvas downsample pixels
remain covered by the independent WebKit renderer oracle, not this Canvas mock.
"""
import hashlib,json,pathlib,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[2]
HERE=pathlib.Path(__file__).resolve().parent
SRC=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
OUT=ROOT/'build/native-render-parity/spatial-crop'
NODE=r'''
const fs=require('fs'),vm=require('vm');
const base=process.argv[1],fixtures=JSON.parse(fs.readFileSync(0,'utf8'));
function script(name){return fs.readFileSync(base+'/'+name+'.swift','utf8').split('static let script = """')[1].split('"""')[0];}
class Canvas{constructor(){this.canvas=this;}getContext(){return this;}
 drawImage(image,x,y,sw,sh,dx,dy,w,h){this.data=new Uint8ClampedArray(w*h*4);
  if(sw!==w||sh!==h||!Number.isInteger(x)||!Number.isInteger(y)){
   if(!image.rgba.every((v,i)=>v===image.rgba[i%4]))throw Error('nonuniform scaled oracle needs WebKit');
   for(let i=0;i<this.data.length;i++)this.data[i]=image.rgba[i%4];return;}
  for(let yy=0;yy<h;yy++)for(let xx=0;xx<w;xx++){const from=((y+yy)*image.naturalWidth+x+xx)*4,to=(yy*w+xx)*4;for(let c=0;c<4;c++)this.data[to+c]=image.rgba[from+c];}}
 getImageData(){return {data:this.data};}}
const source=fs.readFileSync(base+'/BrowserOverlayView.swift','utf8');
const probe=source.slice(source.indexOf('const probeRowEndMarks ='),source.indexOf('// A joined balloon unit'));
let crop=source.slice(source.indexOf('const appendRestoredSourcePanel ='),source.indexOf('const key=JSON.stringify([detached?'));
crop=crop.slice(0,crop.lastIndexOf('try {'))+`return {crop:[x,y,sourceWidth,sourceHeight],width:w,height:h,box:[(b[0]*iw-x)*sx,(b[1]*ih-y)*sy,b[2]*iw*sx,b[3]*ih*sy],auxiliary:auxiliary.map(r=>[(r[0]*iw-x)*sx,(r[1]*ih-y)*sy,r[2]*iw*sx,r[3]*ih*sy]),marks:rowEndMarks.map(r=>[(r[0]*iw-x)*sx,(r[1]*ih-y)*sy,r[2]*iw*sx,r[3]*ih*sy]),excluded:rubyExclusions.map(r=>[(r[0]*iw-x)*sx,(r[1]*ih-y)*sy,r[2]*iw*sx,r[3]*ih*sy]),leadingRule};};`;
const forcedStart=source.indexOf('const auxiliary=(item.auxiliaryInkRects||[]).filter',source.indexOf('const old=restoredPanelGeometry.get(item);',source.indexOf('let remainingPixels=')));
if(forcedStart<0)throw Error('forced crop anchor missing');
const forcedBody=source.slice(forcedStart,source.indexOf('        scratch.width=w;',forcedStart));
const out=[];
for(const f of fixtures){
 const image={complete:true,naturalWidth:f.width,naturalHeight:f.height,rgba:Uint8ClampedArray.from(f.rgba)};
 const item=f.item,others=f.excluded.map(sourceBounds=>({sourceBounds}));
 const c=vm.createContext({sourceImage:image,cleanupCanvas:new Canvas(),items:[item,...others],keptItems:[],
  cleanupImageGeometry:{frame:f.frame||item.sourceFrame},cachedSourceSample:()=>f.sample,performance:{now:()=>0},budgetStop:()=>true,
  inpaintingEnabled:true,opacity:1,panelRestorationBudget:f.budget??1572864,remainingPanelRestorations:f.eligible??1,
  rowEndProbeBudget:f.markBudget??262144,rowEndProbeRemaining:f.eligible??1,rowEndProbeMilliseconds:0,rowEndMarkCount:0,
  adjacentDotBudget:262144,rubyInspectionBudget:262144,slantedPageFallbackBudget:f.detachedBudget??1048576});
 vm.runInContext('cleanupContext=cleanupCanvas;'+script('BrowserSourceGlyphSegmentation')+'\n'+script('BrowserSourceInkCleanup')+'\n'+script('BrowserSourcePanelRestoration')+'\n'+probe+'\n'+crop+'\nglobalThis.plan=appendRestoredSourcePanel;globalThis.budgets=()=>({budget:panelRestorationBudget,rubyBudget:rubyInspectionBudget,markBudget:rowEndProbeBudget,adjacentDotBudget,remaining:remainingPanelRestorations,remainingMarks:rowEndProbeRemaining,detachedBudget:slantedPageFallbackBudget});',c);
 if(f.forced){
  c.f=f;vm.runInContext(`globalThis.force=()=>{const item=f.item,frame=f.frame||item.sourceFrame,b=item.sourceBounds,iw=sourceImage.naturalWidth,ih=sourceImage.naturalHeight;let remainingPixels=f.forcedBudget??6000000,plan=null;const id=item.id,report=()=>{};for(const once of[1]){${forcedBody}
   const sx=w/sourceWidth,sy=h/sourceHeight;plan={crop:[x,y,sourceWidth,sourceHeight],width:w,height:h,box:[(b[0]*iw-x)*sx,(b[1]*ih-y)*sy,b[2]*iw*sx,b[3]*ih*sy],auxiliary:auxiliary.map(r=>[(r[0]*iw-x)*sx,(r[1]*ih-y)*sy,r[2]*iw*sx,r[3]*ih*sy]),marks:[],excluded:f.excluded.map(r=>[(r[0]*iw-x)*sx,(r[1]*ih-y)*sy,r[2]*iw*sx,r[3]*ih*sy]),leadingRule:false,nominalScale:scale};}return {plan,forcedBudget:remainingPixels};};`,c);
  out.push({name:f.name,...c.force(),...c.budgets()});
 }else{const plan=c.plan(item,f.detached===true);out.push({name:f.name,plan:plan||null,...c.budgets()});}
}
process.stdout.write(JSON.stringify(out));
'''
def fixtures():
 result=[]
 def add(name,box=(70,80,24,100),size=(200,300),vertical=True,sample=None,paint=None,**overrides):
  w,h=size;rgba=[255,255,255,255]*(w*h)
  if paint:
   for x,y,ww,hh in paint:
    for yy in range(y,y+hh):
     for xx in range(x,x+ww):rgba[(yy*w+xx)*4:(yy*w+xx)*4+4]=[0,0,0,255]
  b=[box[0]/w,box[1]/h,box[2]/w,box[3]/h]
  item={'id':name,'text':'TEXT','width':24,'height':100,'fontSize':16,'lineHeight':18,'sourceBounds':b,'sourceFrame':[0,0,w,h],
    'sourceFontSize':16,'sourceVertical':vertical,'sourceSingleColumn':vertical,'sourceColorEligible':True,'sourcePanelRestorationEligible':True}
  f={'name':name,'width':w,'height':h,'rgba':rgba,'item':item,'sample':sample or {'foreground':[0,0,0],'background':[255,255,255]},'excluded':[]}
  for key,value in overrides.items():
   if key in ('budget','markBudget','eligible','excluded','detached','detachedBudget','forced','forcedBudget','frame'):f[key]=value
   else:item[key]=value
  result.append(f)
 add('vertical donor punctuation')
 add('tall vertical',box=(70,40,20,220))
 add('horizontal',box=(40,80,100,24),vertical=False)
 add('leading rule',sample={'foreground':[0,0,0],'background':[255,255,255],'stroke':[100,100,100]})
 for name,box in [('left',(1,80,24,100)),('top',(70,1,24,100)),('right',(175,80,24,100)),('bottom',(70,200,24,100)),('corner',(0,0,24,100))]:add('edge '+name,box=box)
 add('edge reduced',box=(0,0,40,150),budget=14_001)
 add('background only neutral',sample={'background':[255,255,255]})
 add('background only inconclusive',sample={'background':[160,170,180]})
 add('lexical ruby preview',sourceCleanupLexical=True)
 add('ruby excluded',sourceCleanupLexical=True,excluded=[[.5,.1,.1,.5]])
 add('auxiliary expands crop',auxiliaryInkRects=[[.5,.6,.02,.02]])
 add('vertical closing mark',paint=[(75,175,5,5),(75,185,5,5)])
 add('horizontal end mark',box=(40,80,100,24),vertical=False,paint=[(145,85,5,5)])
 add('leading dot run',text='……TEXT',paint=[(75,60,4,4),(75,67,4,4),(75,73,4,4)])
 add('native contour adjacent dots',text='……TEXT',paint=[(75,60,4,4),(75,67,4,4),(75,73,4,4)],balloonInterior={'rect':[.1,.05,.8,.9],'center':[.5,.5],'spans':[.1,.9]*20,'contourVerified':True})
 add('fractional mark allowance',markBudget=33_333)
 add('exhausted page',budget=0)
 add('tiny page share',budget=10_000,eligible=8)
 add('last page share',budget=10_000,eligible=1)
 add('probe cap',markBudget=1)
 add('nullable backing edge',box=(0,0,24,100),sample={'foreground':[0,0,0],'background':None})
 add('nullable backing ruby',sourceCleanupLexical=True,sample={'foreground':[0,0,0],'background':None})
 add('paired row ends',paint=[(75,67,5,5),(75,185,5,5)])
 add('open repeated end run',paint=[(75,y,4,4) for y in range(187,270,7)])
 add('observed ruby growth',sourceCleanupLexical=True,paint=[(98,yy,4,8) for yy in (90,104,118,132)])
 add('detached slanted ordinary geometry',detached=True,rotation=.2,budget=0,eligible=8)
 add('detached excludes marks',detached=True,rotation=.2,paint=[(75,175,5,5),(75,185,5,5)])
 add('detached leading rule',detached=True,rotation=.2,sample={'foreground':[0,0,0],'background':[255,255,255],'stroke':[100,100,100]})
 add('detached nullable backing edge',detached=True,rotation=.2,box=(0,0,24,100),sample={'foreground':[0,0,0],'background':None})
 add('detached fair share independent',detached=True,rotation=.2,budget=0,eligible=99,detachedBudget=16000)
 add('detached scale rejected',detached=True,rotation=.2,detachedBudget=10000)
 add('detached exhausted rejected',detached=True,rotation=.2,detachedBudget=0)
 add('detached ruby retained',detached=True,rotation=.2,sourceCleanupLexical=True,paint=[(98,yy,4,8) for yy in (90,104,118,132)])
 add('forced full auxiliary ownership',forced=True,auxiliaryInkRects=[[.35,.27,.02,.02]]*32+[[.8,.7,.05,.02]])
 add('forced fractional glyph padding',forced=True,sourceFontSize=13.13,box=(70.25,80.2,24.4,100.3))
 add('forced nominal scale differs floored axes',forced=True,forcedBudget=15101,box=(70.25,80.2,24.4,100.3),sourceFontSize=13.13)
 add('forced budget refused',forced=True,forcedBudget=1000)
 add('ordinary explicit cleanup frame width',frame=[13,17,100,125],paint=[(80,182,4,3),(80,189,4,3)])
 add('ordinary explicit cleanup frame height',frame=[13,17,200,150],paint=[(80,182,4,3),(80,189,4,3)])
 add('forced explicit cleanup frame width',forced=True,frame=[13,17,100,125],sourceFontSize=13.13)
 add('forced explicit cleanup frame height',forced=True,frame=[13,17,200,150],sourceFontSize=13.13)
 add('forced zero source font cleanup frame',forced=True,frame=[13,17,100,125],sourceFontSize=0)
 return result
def main():
 OUT.mkdir(parents=True,exist_ok=True);fs=fixtures();(OUT/'fixtures.json').write_text(json.dumps(fs))
 model=(SRC/'NativeTranslationLayout.swift').read_text();(OUT/'Models.swift').write_text(model[:model.index('private actor NativeTranslationLayoutWorker')].replace('import UIKit\n',''))
 (OUT/'Shims.swift').write_text('import CoreGraphics\nstruct UIEdgeInsets {var top:CGFloat;var left:CGFloat;var bottom:CGFloat;var right:CGFloat}\nextension CGRect {func inset(by p:UIEdgeInsets)->CGRect{CGRect(x:minX+p.left,y:minY+p.top,width:width-p.left-p.right,height:height-p.top-p.bottom)}}\nenum NativeTranslationLayoutPlanner {static func validGeometry(imageSize:CGSize,sourceRect:CGRect,viewport:CGSize)->Bool{true}}\n')
 names=['NativeEnclosedPaperFinish','NativeSpatialSourceCrop','NativeSourceGlyphSegmentation','NativeTranslationPixelKernels','NativeSourceColorSampler','NativeSourceColorSamplingStage','NativeObservedSourcePalette','NativeCaptionSourcePalette','NativeForcedComponentRestoration','NativeForcedSourceInpainting','NativeConnectedLettering']
 files=set(SRC/(n+'.swift') for n in names)
 for pattern in ['NativeRestoration*.swift','NativeObservedRestore*.swift','NativeObservedRestoration*.swift','NativeResidual*.swift']:files.update(SRC.glob(pattern))
 files={p for p in files if p.stem != 'NativeRestorationCandidate' and 'extension NativeTranslationRestoration' not in p.read_text()} # Uncalled renderer-only extensions.
 snapshot=OUT/'source';snapshot.mkdir(exist_ok=True)
 paths=[];digest=hashlib.sha256()
 for p in sorted(files):
  raw=p.read_bytes();(snapshot/p.name).write_bytes(raw);paths.append(str(snapshot/p.name));digest.update(raw)
 lib=ROOT/'build/native-overlay-kernels-host/libAidokuOverlayKernels.a';digest.update(str(lib.stat().st_mtime_ns).encode())
 mainraw=(HERE/'SpatialCropParityMain.swift').read_bytes();(OUT/'main.swift').write_bytes(mainraw);digest.update(mainraw)
 digest.update((OUT/'Models.swift').read_bytes());digest.update((OUT/'Shims.swift').read_bytes())
 cache=OUT/'build-hash';binary=OUT/'native'
 if not binary.exists() or not cache.exists() or cache.read_text()!=digest.hexdigest():
  subprocess.run(['swiftc','-swift-version','6','-O','-I',str(ROOT/'Scripts/overlay-kernels/native'),str(OUT/'Models.swift'),str(OUT/'Shims.swift'),*paths,str(OUT/'main.swift'),str(lib),'-o',str(binary)],check=True);cache.write_text(digest.hexdigest())
 subprocess.run([str(binary),str(OUT/'fixtures.json'),str(OUT/'native.json')],check=True)
 browser=json.loads(subprocess.check_output(['node','-e',NODE,str(HERE/'reference-source')],input=json.dumps(fs).encode()));(OUT/'browser.json').write_text(json.dumps(browser))
 native=json.loads((OUT/'native.json').read_text())
 def equal(a,b):
  if isinstance(a,(float,int)) and not isinstance(a,bool) and isinstance(b,(float,int)) and not isinstance(b,bool):return abs(a-b)<=1e-8
  if type(a)!=type(b):return False
  if isinstance(a,list):return len(a)==len(b) and all(equal(x,y) for x,y in zip(a,b))
  if isinstance(a,dict):return a.keys()==b.keys() and all(equal(a[k],b[k]) for k in a)
  return a==b
 failures=[{'name':a['name'],'native':a,'browser':b} for a,b in zip(native,browser) if not equal(a,b)]
 report={'fixtures':len(fs),'passed':len(fs)-len(failures),'failed':failures,'scope':'production crop/probe plans and budgets; 1e-8 point tolerance; independent WebKit needed for nonuniform downsample pixels'}
 (OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps({'fixtures':len(fs),'passed':report['passed'],'failed':[x['name'] for x in failures]}));raise SystemExit(bool(failures))
if __name__=='__main__':main()
