#!/usr/bin/env python3
"""Frozen whole slanted search policy with shared deterministic shaping/proof queries.

This checks chronology and commits, independently of the CoreText/DOM adapter and
pixel-ownership kernels, which have separate actual-renderer probes.
"""
import json, pathlib, subprocess, random, hashlib
ROOT=pathlib.Path(__file__).resolve().parents[2];HERE=pathlib.Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/slanted-typography';SRC=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
NODE=r'''
const fs=require('fs'),vm=require('vm'),base=process.argv[1],fixtures=JSON.parse(fs.readFileSync(0,'utf8'));
const view=fs.readFileSync(base+'/BrowserOverlayView.swift','utf8'),color=fs.readFileSync(base+'/BrowserSourceTextColor.swift','utf8').split('static let script = """')[1].split('"""')[0];
const start=view.indexOf('const originalFont=parseFloat(node.style.fontSize);',view.indexOf('node.dataset.slantedSourcePrepared'));
const end=view.indexOf('          // An upright plate is clipped',start);
if(start<0||end<0)throw Error('slanted body missing');
let body=view.slice(start,end);body=body.slice(0,body.lastIndexOf('          }')); // outer inpainting block close
body=body.replaceAll('\\\\','\\');
const uprightStart=view.indexOf('const upright = item.uprightAlternative;'),uprightEnd=view.indexOf('          // A vertical column tilted',uprightStart);
const uprightBody=view.slice(uprightStart,uprightEnd).replaceAll('\\\\','\\');
const clipStart=view.indexOf('const quadOutline = uprightQuad'),clipEnd=view.indexOf("node.dataset.sourcePanelTextFit = 'caption';",clipStart),clipBody=view.slice(clipStart,clipEnd);
const fitStart=view.indexOf('const fitMeasuredFont = maximum =>'),fitEnd=view.indexOf('        // Fit in the quad',fitStart),fitBody=view.slice(fitStart,fitEnd);
const baseStart=view.indexOf('const plannedRotatedFont = Number.isFinite'),baseEnd=view.indexOf('node.dataset.sourceRotation =',baseStart),baseBody=view.slice(baseStart,baseEnd);
const slanted=fs.readFileSync(base+'/BrowserSlantedSourceRestoration.swift','utf8').split('static let script = """')[1].split('"""')[0];
const c=vm.createContext({performance:{now:()=>0}});vm.runInContext(color,c);vm.runInContext(slanted,c);
vm.runInContext(`globalThis.run=f=>{
 const quad=f.quad||[50,60,90,45], [x,y,width,height]=quad,fontSize=f.font||12,padding=f.padding||[2,2,2,2],lineHeightRatio=f.ratio||1.2;
 const text=f.text||'HELLO WORLD',displayedText=text,minimumFontSize=f.minimum||5,plannedRotatedFont=f.planned??null,vertical=f.vertical||false,wrappingScript=f.korean?'korean':'latin';
 const sourceImage={naturalWidth:500,naturalHeight:500},cleanupImageGeometry={frame:[0,0,500,500]},scrollX=0,scrollY=0,foreground=(f.foreground||[0,0,0]).join(',');
 const item={sourceColorEligible:true,id:f.name,text:f.sourceText||'',x,y,width,height,rotation:f.angle??.2,sourceBounds:quad.map(v=>v/500),sourceFrame:[0,0,500,500],sourceFontSize:f.glyph||20,sourceVertical:f.sourceVertical||false};
 const items=[item,...(f.peers||[]).map(p=>({id:p.text,x:p.rect[0],y:p.rect[1],width:p.rect[2],height:p.rect[3],text:p.text||'',fontSize:p.font||12,sourceFontSize:p.glyph||20,sourceBounds:p.rect.map(v=>v/500),rotation:0}))],keptItems=[];
 const style={left:String(x),top:String(y),width:String(width),height:String(height),fontSize:String(fontSize),lineHeight:String(fontSize*lineHeightRatio),paddingTop:String(padding[0]),paddingRight:String(padding[1]),paddingBottom:String(padding[2]),paddingLeft:String(padding[3]),fontWeight:'400',fontFamily:'Fixture',visibility:'visible'};
 function stylify(s){Object.defineProperty(s,'padding',{get(){return [this.paddingTop,this.paddingRight,this.paddingBottom,this.paddingLeft].join(' ');},set(v){const p=v.split(' ');[this.paddingTop,this.paddingRight,this.paddingBottom,this.paddingLeft]=p;},enumerable:true,configurable:true});return s;}
 const node={style:stylify({...style}),dataset:{sourceBackgroundColor:'rotated-panel'},getBoundingClientRect(){return {left:parseFloat(this.style.left),top:parseFloat(this.style.top),width:parseFloat(this.style.width),height:parseFloat(this.style.height)};}};
 const measurementNode={style:stylify({...style}),firstChild:{nodeType:3,textContent:text},getBoundingClientRect(){return {left:parseFloat(this.style.left),top:parseFloat(this.style.top),width:parseFloat(this.style.width),height:parseFloat(this.style.height)};},remove(){}};
 function shape(){let s=measurementNode.style,size=parseFloat(s.fontSize),pitch=parseFloat(s.lineHeight),W=parseFloat(s.width),H=parseFloat(s.height),a=size*.5,avail=Math.max(.01,W-parseFloat(s.paddingLeft)-parseFloat(s.paddingRight)),cols=Math.max(1,Math.floor(avail/a)),chars=Array.from(text),rows=Math.max(1,Math.ceil(chars.length/cols));
  const top=parseFloat(s.paddingTop)+(H-parseFloat(s.paddingTop)-parseFloat(s.paddingBottom)-rows*pitch)/2+(pitch-size)/2;
  const make=(i,count=1)=>{const r=Math.floor(i/cols),col=i%cols,left=parseFloat(s.left)+parseFloat(s.paddingLeft)+col*a,t=parseFloat(s.top)+top+r*pitch;return {left,top:t,right:left+count*a,bottom:t+size,width:count*a,height:size};};
  return {chars,cols,rows,make,lines:Array.from({length:rows},(_,r)=>make(r*cols,Math.min(cols,chars.length-r*cols))),fits:rows*pitch+parseFloat(s.paddingTop)+parseFloat(s.paddingBottom)<=H+.5&&a<=avail+.5};}
 const document={createRange:()=>({selectNodeContents(n){this.all=true;},setStart(t,i){this.start=i;this.all=false;},setEnd(t,i){this.end=i;},getClientRects(){const sh=shape();if(this.all)return sh.lines;return [sh.make(this.start)];}})};
 const Node={TEXT_NODE:3},root={appendChild(){},querySelector(){return null},querySelectorAll(){return []}},CSS={escape:s=>s},getComputedStyle=n=>n.style;
 let currentFont=fontSize;const koreanWrapMeasure={measureText:()=>({})},setKoreanFont=s=>{currentFont=parseFloat(s.split(' ')[1]);},koreanTextWidth=t=>Array.from(t).length*currentFont*.5;
 const applyMeasuredFontSize=size=>{for(const n of[node,measurementNode]){n.style.fontSize=String(size);n.style.lineHeight=String(size*lineHeightRatio);}},contentFits=()=>shape().fits;
 let slantedCondense=1,uprightQuad=f.upright||false,textAngle=uprightQuad?0:item.rotation;
 const quadBox=[x,y,width,height],slantedGlyphCards=new Map(),liftedSlanted=new Set(),pendingSlantedLifts=[];let slantedLiftLayouts=f.budget??600;
 const aidokuReadableFontSize=9,aidokuReadableMinimum=8.5,aidokuCondensedWidth=.9,aidokuCondensedWordBound=(longest,avail)=>longest>avail&&longest*.9<=avail;
 const aidokuGrowthKeepsLineLength=(text,before,after)=>{const n=text.replace(/\\s/gu,'').length;return n>0&&Number.isFinite(after)&&after>=1&&(after<3||n<8||n/after>=2.5||n/after>=n/Math.max(1,before));};
 const canvas={style:{left:String(x),top:String(y)},width:12,height:12,remove(){},replaceWith(){}};
 let restored=f.noSurface?null:{canvas,scale:1,rasterScale:1,result:{method:f.method||'rectified',lw:12,lh:12,box:[0,0,12,12],layoutSafe:new Uint8Array(144).fill(1),luminance:new Uint8Array(144).fill(245),rgba:new Uint8ClampedArray(576)}};
 if(f.paper)restored.result.layoutSafe=Uint8Array.from({length:144},(_,i)=>i%12>=2&&i%12<10&&Math.floor(i/12)>=2&&Math.floor(i/12)<10?1:0);
 const sampled={foreground:f.foreground||[0,0,0],...(f.observed?{foreground:f.observed}:{})},appearance={preserveSourceTextColor:true,preserveSourceBackgroundColor:true};
 const aidokuCaptionPalette=()=>({foreground:f.foreground||[0,0,0]}),cachedSourceSample=()=>sampled;
 let proofCalls=0;
 function inkFits(surface,rs,left,nodeWidth,color,audit){proofCalls++;const s=node.style,size=parseFloat(s.fontSize),fraction=1-(parseFloat(s.paddingLeft)+parseFloat(s.paddingRight)-padding[1]-padding[3])/width;
  const lifted=f.allowLift&&parseFloat(s.paddingTop)===0&&size>=8.5;
  const paper=surface.result.layoutSafe.reduce((a,v)=>a+v,0)>64&&f.paper,safeFont=surface.wide?(f.wideSafeFont??f.safeFont??100):paper?(f.paperSafeFont??f.safeFont??100):(f.safeFont??100);
  const geometry=size<=safeFont&&(lifted||fraction<=(f.safeFraction??1)+1e-8)&&parseFloat(s.width)>=(f.safeWidth??0)&&(!f.rotatedOnly||textAngle!==0)&&rs.length>0;
  const unsafe=geometry?(f.unsafe||0):20,byte=f.surfaceByte??245,l=aidokuSourceColorLuminance(color),q=byte/255,contrast=(Math.max(l,q)+.05)/(Math.min(l,q)+.05),dim=contrast>=4.5?(f.dim||0):1000;
  Object.assign(audit,{minimumContrast:contrast,unsafe,unsafeDim:0,dim,samples:1000,range:[byte,byte]});if(audit.histogram)audit.histogram[byte]=1000;
  return unsafe===0&&dim===0&&contrast>=4.5;}
 const aidokuSlantedInkFits=(r,rs,scale,color,audit)=>inkFits({result:r,wide:r.wide},rs,0,0,color,audit);
 const aidokuPlateLeftoverInk=()=>({area:144,ink:f.leftover??10});
 const prepareSlantedSourcePanel=(item,card)=>f.mode==='upright'?restored:f.wide?{...restored,result:{...restored.result,wide:true},canvas:{...canvas,style:{left:String(card.x),top:String(card.y)},remove(){},replaceWith(){}},wide:true}:null;
 const aidokuErasureOffQuad=()=>({erased:100,off:0});
 if(f.mode==='clip'||f.mode==='baseline'){
  if(f.mode==='clip')uprightQuad=true;
  else item.rotationPlannedFontSize=f.planned;
  ${fitBody}
  if(f.mode==='baseline'){${baseBody}}
  if(f.mode==='clip'){textAngle=0;${clipBody}}
  const s=node.style,metadata={};if(node.dataset.uprightQuadFit)metadata.uprightQuadFit=node.dataset.uprightQuadFit;
  const out={name:f.name,accepted:false,candidate:['left','top','width','height','fontSize','lineHeight'].map(k=>parseFloat(s[k])).concat([1,textAngle]),padding:['paddingTop','paddingRight','paddingBottom','paddingLeft'].map(k=>parseFloat(s[k])),fraction:1,foreground:f.foreground||[0,0,0],surface:'original',pending:false,budget:slantedLiftLayouts,proofCalls,metadata};
  if(f.mode==='clip')out.clip=(s.clipPath.match(/[-0-9.e+]+px [-0-9.e+]+px/g)||[]).map(t=>t.match(/[-0-9.e+]+/g).map(Number));
  return out;
 }
 if(f.mode==='upright'){
  const a=f.alternative||quad,p=f.alternativePadding||padding,af=f.alternativeFont||fontSize;
  item.uprightAlternative={x:a[0],y:a[1],width:a[2],height:a[3],fontSize:af,lineHeight:af*lineHeightRatio,paddingTop:p[0],paddingRight:p[1],paddingBottom:p[2],paddingLeft:p[3]};
  const inpaintingEnabled=true,opacity=1;let renderedItemCount=0;
  for(const once of[1]){${uprightBody}}
  const s=node.style,metadata={};for(const k of ['uprightFromSlant','sourceBackgroundColor','uprightSourceRotation','sourceContrastAfter','slantedInkSpecks'])if(node.dataset[k]!==undefined)metadata[k]=node.dataset[k];
  const accepted=node.dataset.uprightFromSlant==='true',contentWidth=a[2]-p[1]-p[3],fraction=1-(parseFloat(s.paddingLeft)+parseFloat(s.paddingRight)-p[1]-p[3])/contentWidth;
  return {name:f.name,accepted,candidate:['left','top','width','height','fontSize','lineHeight'].map(k=>parseFloat(s[k])).concat([1,accepted?0:item.rotation]),padding:['paddingTop','paddingRight','paddingBottom','paddingLeft'].map(k=>parseFloat(s[k])),fraction,foreground:s.color?s.color.match(/[0-9.]+/g).map(Number):f.foreground||[0,0,0],surface:'original',pending:false,budget:slantedLiftLayouts,proofCalls,metadata};
 }
 ${body}
 if(f.lift)pendingSlantedLifts.forEach(fn=>fn());
 const s=node.style,keys=['left','top','width','height','fontSize','lineHeight'];let candidate=keys.map(k=>parseFloat(s[k])).concat([slantedCondense,textAngle]);
 const metadata={};for(const k of['slantedOriginalFont','slantedBaseFont','slantedFontFloor','sourceContrastAfter','slantedTextWidthFraction','slantedInkSpecks','displayGrowth','bodyGrowth','bodyCondensed','uprightQuad','slantedPlateLeftover','slantedUnprovenPixels','slantedTextWidened','sourceBackgroundColor','readableLift','readablePeer','readableLiftBox','readableLiftSurface'])if(node.dataset[k]!==undefined)metadata[k]=node.dataset[k];
 return {name:f.name,accepted,padding:['paddingTop','paddingRight','paddingBottom','paddingLeft'].map(k=>parseFloat(s[k])),candidate,foreground:s.color?s.color.match(/[0-9.]+/g).map(Number):f.foreground||[0,0,0],fraction:Number(node.dataset.slantedTextWidthFraction||1),surface:node.dataset.readableLiftSurface==='widened'||acceptedSurface?.wide?'wide':acceptedSurface?'original':null,pending:accepted&&!f.lift&&!vertical&&wrappingScript==='korean'&&parseFloat(s.fontSize)<8.5,budget:slantedLiftLayouts,proofCalls,metadata};
};`,c);
process.stdout.write(JSON.stringify(fixtures.map(f=>c.run(f))));
'''
def fixtures():
 fs=[]
 def add(name,**kw): fs.append({'name':name,**kw})
 add('initial font fit nine bisections',mode='baseline',font=32,quad=[50,60,40,42],planned=12)
 add('initial min font cannot fit',mode='baseline',font=32,quad=[50,60,5,6],minimum=7)
 add('initial planned word line gate',mode='baseline',font=22,quad=[50,60,50,110],planned=9)
 add('upright plate quad clip shrinks',mode='clip',font=20,quad=[50,60,80,28],angle=.65)
 add('upright plate page corner clip',mode='clip',font=12,quad=[0,0,80,45],angle=.4)
 add('upright plate unchanged inside',mode='clip',font=12,quad=[50,60,130,65],angle=.1)
 add('body condensed keeps words',font=12,glyph=28,quad=[50,60,132,55],text='VERYLONGWORD')
 add('body same-text peer cap',font=12,glyph=28,quad=[50,60,140,55],sourceText='SOURCE',peers=[{'rect':[220,60,140,55],'text':'SOURCE','font':12,'glyph':28}])
 add('body overlap refuses growth',font=12,glyph=28,quad=[50,60,140,55],peers=[{'rect':[55,62,100,45],'font':12,'glyph':28}])
 add('upright accepts large whole word',mode='upright',font=12,alternativeFont=15,alternative=[45,55,130,65])
 add('upright word breaking rejects',mode='upright',font=12,alternative=[50,60,20,130])
 add('upright margin rejects neighbor',mode='upright',font=12,alternative=[50,60,90,45],peers=[{'rect':[55,62,70,40],'font':12}])
 add('upright narrows source proof',mode='upright',font=12,alternative=[50,60,90,45],safeFraction=.8)
 add('upright rejects all unsafe',mode='upright',font=12,unsafe=20)
 add('upright declines below art floor',mode='upright',font=20,safeFont=8)
 add('strict source first',font=12)
 add('display grows whole words',font=10,glyph=70,quad=[50,60,220,90])
 add('body growth exact',font=12,glyph=24,quad=[50,60,140,55])
 add('source polarity corrected',foreground=[180,180,180],observed=[180,180,180])
 add('interior gray neutral',foreground=[125,125,125],surfaceByte=50)
 add('unsafe geometry no neutral admission',safeFont=7,minimum=5)
 add('planned coarse then fine',font=30,planned=15,safeFont=12,glyph=20)
 add('upright restores rotation',upright=True,rotatedOnly=True)
 add('fraction reflow',font=13,glyph=20,safeFraction=.7,sourceVertical=True)
 add('narrow paper reflow',font=13,glyph=20,safeFraction=.5,sourceVertical=True,method='rectified-narrow-paper-glyphs',quad=[50,60,30,130])
 add('loose border admitted',font=12,unsafe=2,leftover=2)
 add('loose leftover refused',font=12,unsafe=2,leftover=3)
 add('loose dim admitted',font=12,dim=2,leftover=0)
 add('loose too dim refused',font=12,dim=3,leftover=0)
 add('widen whole words',font=6,glyph=6,quad=[50,60,25,110],sourceVertical=True,korean=True)
 add('deferred readable lift',font=6,glyph=6,quad=[50,60,60,110],sourceVertical=True,korean=True,lift=True)
 add('accepted deferred lift',font=6,glyph=6,quad=[50,60,60,110],sourceVertical=True,korean=True,lift=True,allowLift=True)
 add('flat paper lift retry',font=6,glyph=6,quad=[50,60,60,110],sourceVertical=True,korean=True,lift=True,allowLift=True,paper=True,safeFont=6,paperSafeFont=9)
 add('owned widened lift retry',font=6,glyph=6,quad=[50,60,60,110],sourceVertical=True,korean=True,lift=True,allowLift=True,safeFont=6,wideSafeFont=9,wide=True)
 add('deferred zero budget',font=6,glyph=6,quad=[50,60,60,110],sourceVertical=True,korean=True,lift=True,budget=0)
 add('deferred budget exhausted',font=6,glyph=6,quad=[50,60,60,110],sourceVertical=True,korean=True,lift=True,budget=1)
 add('no source keeps fallback',font=12,noSurface=True)
 rng=random.Random(20260930)
 for i in range(100):
  add('matrix '+str(i),font=rng.choice([6,8,12,18,24]),planned=rng.choice([None,6,10,14]),glyph=rng.choice([6,16,28,50]),
      quad=[50,60,rng.choice([25,60,120,220]),rng.choice([40,80,130])],safeFont=rng.choice([6,9,14,30,100]),sourceVertical=rng.random()<.5,korean=rng.random()<.5,
      unsafe=rng.choice([0,0,2,10]),leftover=rng.choice([0,3]),safeFraction=rng.choice([1,1,.8,.6]),foreground=rng.choice([[0,0,0],[255,255,255],[180,60,80]]))
 return fs

def main():
 OUT.mkdir(parents=True,exist_ok=True);fs=fixtures();(OUT/'fixtures.json').write_text(json.dumps(fs))
 audit=(SRC/'NativeSlantedInkSafety.swift').read_text();a=audit.index('    struct Audit {');b=audit.index('    static func finish',a)
 (OUT/'Audit.swift').write_text('import Foundation\nenum NativeSlantedInkSafety {\n'+audit[a:b]+'}\n')
 (OUT/'main.swift').write_text((HERE/'SlantedTypographyParityMain.swift').read_text())
 paths=[SRC/'NativeSlantedTypographyTrial.swift',SRC/'NativeSlantedGeometry.swift',SRC/'NativeTranslationSourceStylePostPolish.swift',OUT/'Audit.swift']
 subprocess.run(['swiftc','-swift-version','6','-O',*map(str,paths),str(OUT/'main.swift'),'-o',str(OUT/'native')],check=True)
 subprocess.run([str(OUT/'native'),str(OUT/'fixtures.json'),str(OUT/'native.json')],check=True)
 js=subprocess.run(['node','-e',NODE,str(HERE/'reference-source')],input=json.dumps(fs),text=True,capture_output=True)
 if js.returncode: print(js.stderr);raise SystemExit(js.returncode)
 (OUT/'web.json').write_text(js.stdout)
 native=json.loads((OUT/'native.json').read_text());web=json.loads(js.stdout)
 def equal(a,b):
  if isinstance(a,(int,float)) and isinstance(b,(int,float)):return abs(a-b)<1e-7
  if isinstance(a,dict) and isinstance(b,dict):return a.keys()==b.keys() and all(equal(a[k],b[k]) for k in a)
  if isinstance(a,list) and isinstance(b,list):return len(a)==len(b) and all(equal(x,y) for x,y in zip(a,b))
  if isinstance(a,str) and isinstance(b,str):
   try:return abs(float(a)-float(b))<1e-7
   except ValueError:
    for sep in ['->','x']:
     if sep in a and sep in b:return equal(a.split(sep),b.split(sep))
  return a==b
 failures=[]
 for a,b in zip(native,web):
  # Query count differs where equivalent pure queries replace mutable DOM reads.
  a.pop('proofCalls');b.pop('proofCalls')
  if not equal(a,b):failures.append({'name':a['name'],'native':a,'web':b})
 report={'cases':len(fs),'passed':len(fs)-len(failures),'failures':failures,'scope':'Actual frozen full slanted body with identical deterministic shaping and surface proof queries; excludes actual font/raster adapter pixels.'}
 (OUT/'report.json').write_text(json.dumps(report,indent=2));print(f"{report['passed']}/{len(fs)} exact policy cases")
 if failures: print(json.dumps(failures[:2],indent=2));raise SystemExit(1)
if __name__=='__main__':main()
