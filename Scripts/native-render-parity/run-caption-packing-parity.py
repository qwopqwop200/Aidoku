#!/usr/bin/env python3
"""Actual frozen unified caption orchestration versus native typed pipeline.

Measurements are physical ink supplied identically to both callers, isolating
packing policy from independently tested typography and native Canvas pixels.
"""
import copy,hashlib,json,pathlib,random,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[2];HERE=pathlib.Path(__file__).resolve().parent
SRC=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';OUT=ROOT/'build/native-render-parity/caption-packing'
NODE=r'''
const fs=require('fs'),vm=require('vm'),base=process.argv[1],fixtures=JSON.parse(fs.readFileSync(0,'utf8'));
const source=fs.readFileSync(base+'/BrowserOverlayView.swift','utf8'),start=source.indexOf('const panels=Array.from',source.indexOf('// Commit each opaque caption')),end=source.indexOf('// A rejected partition retains',start),body=source.slice(start,end);
const initial=source.slice(source.indexOf('if(opacity===1&&items.length<=256)',source.indexOf('// Commit each opaque caption')),start);
const typography=fs.readFileSync(base+'/BrowserOverlayTypography.swift','utf8').split('static let script = #"""')[1].split('"""#')[0];
function style(initial){const s={...initial};Object.defineProperty(s,'cssText',{get(){return JSON.stringify(Object.entries(s));},set(v){for(const k of Object.keys(s))delete s[k];Object.assign(s,Object.fromEntries(JSON.parse(v)));}});return s;}
const outputs=[];
for(const f of fixtures){
 const rect=a=>({left:a[0],top:a[1],right:a[0]+a[2],bottom:a[1]+a[3],width:a[2],height:a[3]});
 const box=n=>n.kind==='node'&&n.parentNode===root?rect(n.descriptor.box||n.descriptor.ink):rect(['left','top','width','height'].map(k=>parseFloat(n.style[k])));
 const root={dataset:{},kind:'root',insertBefore(n){n.parentNode=this;n.parentElement=this;},querySelectorAll(selector){return selector.includes('overlay="item"')?nodes:selector.includes('source-readability-backing')&&selector.includes('source-readability-panel')?panels.filter(p=>!p.removed):selector.includes('source-readability-backing')?panels.filter(p=>p.backing&&!p.removed):panels.filter(p=>!p.backing&&!p.removed);}};
 const panels=[],nodes=[];
 const items=f.entries.map(e=>({id:e.id,text:e.text,sourceBounds:e.source?[ (e.source[0]-f.page[0])/f.page[2],(e.source[1]-f.page[1])/f.page[3],e.source[2]/f.page[2],e.source[3]/f.page[3]]:null,sourceFrame:f.page,sourceFontSize:e.sourceFont,vertical:e.vertical,rotation:e.rotation,balancedColumn:e.balancedColumn}));
 for(const e of f.entries){
  const n={kind:'node',descriptor:e,style:style({fontSize:String(e.font),lineHeight:String(e.font*(e.ratio||1.2)),transform:e.rotation?'rotate(1rad)':'none'}),dataset:{aidokuRegion:e.id,sourceBackgroundColor:e.readabilityPanel===false?'other':'readability-panel',sourceErasurePreserved:e.erasurePreserved?'true':''},parentNode:root,parentElement:root,children:[],childNodes:[],firstChild:null,nextSibling:null,
   appendChild(){},replaceChildren(){},getBoundingClientRect(){return box(this);},textContent:e.text};
  if(e.originalFont)n.dataset.artworkOriginalFont=String(e.originalFont);
  Object.defineProperties(n,{clientWidth:{get(){return (e.box||e.ink)[2];}},clientHeight:{get(){return (e.box||e.ink)[3];}},scrollWidth:{get(){return n.clientWidth+(e.valid===false?2:0);}},scrollHeight:{get(){return n.clientHeight;}}});nodes.push(n);
  for(const p of e.panels){
   const panel={kind:'panel',backing:!!p.backing,style:style({left:p.rect[0]+'px',top:p.rect[1]+'px',width:p.rect[2]+'px',height:p.rect[3]+'px',borderRadius:'3px',backgroundColor:'rgb('+p.color.join(',')+')',backgroundImage:'none'}),dataset:{aidokuRegion:e.id,sourceErasure:p.erasure?'true':'false',aidokuImageOcrOverlay:p.backing?'source-readability-backing':'source-readability-panel'},
    appendChild(n){n.parentNode=this;n.parentElement=this;},getBoundingClientRect(){return box(this);},remove(){this.removed=true;}};
   if(p.clipped)panel.style.clipPath='path(old)';panels.push(panel);
  }
 }
 function ink(n){
  if(n.parentNode===root)return rect(n.overrideInk||n.descriptor.ink);
  const cell=box(n.parentNode),e=n.descriptor,font=parseFloat(n.style.fontSize),demand=e.demand*font,available=Math.max(0,cell.width-6),lines=Math.max(1,Math.ceil(demand/Math.max(1,available))),width=Math.min(demand,available)+(e.overshoot||0),height=font*(e.ratio||1.2)*lines;
  const dx=parseFloat(n.style.left)||0,dy=parseFloat(n.style.top)||0;
  return rect([cell.left+(cell.width-width)/2+dx,cell.top+(cell.height-height)/2+dy,width,height]);
 }
 const image={complete:true,naturalWidth:f.page[2],naturalHeight:f.page[3]};
 class Canvas{getContext(){return this;}drawImage(img,x,y,sw,sh,dx,dy,w,h){this.p=new Uint8ClampedArray(w*h*4);const col=f.sourceColor||[255,255,255];for(let i=0;i<this.p.length;i+=4){this.p.set([...col,255],i);}}getImageData(){return {data:this.p};}}
 const c=vm.createContext({root,items,opacity:1,unitResidueRisk:new Set(items.filter((item,i)=>f.entries[i].unitResidue)),typographyInkFrames:new Map(),
   unitMembersOf:item=>f.entries.find(e=>e.id===item.id).unit?[{}]:null,
   balloonRectsOf:item=>(f.entries.find(e=>e.id===item.id).relayout?.sources||[]).map(rect),
   sourceRectOf:item=>{const e=f.entries.find(e=>e.id===item.id);return e.source?rect(e.source):null;},
   balloonInteriorOf:item=>({outside:()=>f.entries.find(e=>e.id===item.id).relayout?.outside??Infinity}),
   relayoutInBalloon:(item,node)=>{const v=node.descriptor.relayout;if(!v)return null;const old=node.overrideInk,size=node.style.fontSize;node.overrideInk=v.ink;node.style.fontSize=String(v.font);node.style.lineHeight=String(v.font*(node.descriptor.ratio||1.2));node.dataset.balloonInteriorLayout='{}';return {ink:rect(v.ink),restore(){node.overrideInk=old;node.style.fontSize=size;}};},sourceImage:image,cleanupImageGeometry:{frame:f.page},minimumFontSize:f.minimum||5,scrollX:0,scrollY:0,
   document:{createRange:()=>({selectNodeContents(n){this.n=n;},getBoundingClientRect(){return ink(this.n);}}),createElement:kind=>kind==='canvas'?new Canvas():{}},
   getComputedStyle:n=>n.style,CSS:{supports:()=>true},performance:{now:()=>0}});
 vm.runInContext(typography+'\n'+initial+'\n'+body,c);
 outputs.push({name:f.name,measurements:Number(root.dataset.captionPreflightMeasurements),balloonLayouts:Number(root.dataset.balloonInteriorLayouts||0),fallbacks:Number(root.dataset.captionPreflightFallbacks),entries:nodes.map(n=>{
  const unified=n.dataset.unifiedCaption==='true',active=panels.filter(p=>p.dataset.aidokuRegion===n.dataset.aidokuRegion&&!p.removed);
  const p=unified?n.parentNode:null;
  return {id:n.dataset.aidokuRegion,font:parseFloat(n.style.fontSize),ink:Object.values(ink(n)).slice(0,0).concat([ink(n).left,ink(n).top,ink(n).width,ink(n).height]),cell:p?['left','top','width','height'].map(k=>parseFloat(p.style[k])):null,unified,fit:n.dataset.unifiedCaptionFit||null,compact:n.dataset.captionCompactOriginal?(()=>{const r=JSON.parse(n.dataset.captionCompactOriginal);return [r.left,r.top,r.right-r.left,r.bottom-r.top]})():null,
   panels:active.map(p=>({rect:['left','top','width','height'].map(k=>parseFloat(p.style[k])),color:p.style.backgroundColor.match(/[0-9.]+/g).map(Number),radius:parseFloat(p.style.borderRadius),clipped:!!p.style.clipPath&&p.style.clipPath!=='none',coverage:p.dataset.panelCoverage?JSON.parse(p.dataset.panelCoverage):[]})),shift:n.dataset.finalSourceAnchorShift?JSON.parse(n.dataset.finalSourceAnchorShift):null,foreign:p?.dataset.foreignFills?JSON.parse(p.dataset.foreignFills).map(a=>({rect:a.slice(0,4),color:a[4].match(/[0-9.]+/g).map(Number)})):[]};
 })});
}
process.stdout.write(JSON.stringify(outputs));
'''
def fixtures():
 fs=[];rng=random.Random(731)
 def entry(id,ink,plate,font=12,demand=5,source=None,**extra):
  return {'id':id,'text':'CAPTION TEXT','font':font,'demand':demand,'ink':ink,'box':[ink[0]-1,ink[1]-1,ink[2]+2,ink[3]+2],'panels':[{'rect':plate,'color':[255,255,255]}], 'source':source or ink,'valid':True,**extra}
 def add(name,entries,**kw):fs.append({'name':name,'page':[0,0,300,300],'entries':entries,**kw})
 add('single accepted',[entry('a',[50,55,60,15],[40,40,85,50])])
 add('two group accepted',[entry('a',[50,55,60,15],[40,40,85,50]),entry('b',[110,65,60,15],[100,55,85,50])])
 add('group floor preserved',[entry('a',[50,55,60,15],[40,40,85,50],demand=30),entry('b',[110,65,60,15],[100,55,85,50],demand=30)])
 add('original artwork floor veto',[entry('a',[50,55,60,15],[40,40,85,50],originalFont=30),entry('b',[110,65,60,15],[100,55,85,50])])
 add('frame lines veto widened side',[entry('a',[35,55,95,15],[40,40,85,50])],sourceColor=[0,0,0])
 add('page edge clipped',[entry('a',[-5,25,35,15],[0,10,50,55],demand=3)])
 add('old invalid location may repair',[entry('a',[170,55,60,15],[40,40,85,50],valid=False),entry('b',[110,65,60,15],[100,55,85,50],valid=False)])
 add('source anchor rejects far packing',[entry('a',[50,55,60,15],[40,40,85,50],source=[40,50,40,20]),entry('b',[110,65,60,15],[100,55,85,50],source=[170,60,15,15])])
 add('vertical finalanchor skipped',[entry('a',[50,55,60,15],[40,40,85,50],vertical=True)])
 add('balanced finalanchor skipped',[entry('a',[50,55,60,15],[40,40,85,50],balancedColumn=True)])
 add('rotated caption skipped',[entry('a',[50,55,60,15],[40,40,85,50],rotation=.2)])
 add('minimum too large preserves old',[entry('a',[50,55,60,15],[40,40,85,50])],minimum=20)
 add('overshoot cannot unlock fit',[entry('a',[50,55,60,15],[40,40,85,50],overshoot=3)])
 for name,unit,outside,residue in [('ordinary growth rejected',False,0,False),('unit growth accepted',True,2,False),('unit growth exceeds contour',True,3,False),('unit residue growth rejected',True,0,True)]:
  e=entry('a',[55,55,20,15],[50,50,30,25],demand=2,unit=unit,unitResidue=residue);e['relayout']={'font':12,'ink':[35,55,50,15],'sources':[[50,50,20,15]],'outside':outside};add('balloon '+name,[e])
 e=entry('a',[55,55,20,15],[40,40,60,60],demand=2);e['relayout']={'font':12,'ink':[55,55,20,15],'sources':[[55,55,20,15]],'outside':0};add('balloon plate shrinks',[e])
 for flag in ['erasurePreserved','readabilityPanel','rotation','extraBacking','clipped']:
  e=entry('a',[55,55,20,15],[40,40,60,60],demand=2);e['relayout']={'font':12,'ink':[55,55,20,15],'sources':[[55,55,20,15]],'outside':0}
  if flag=='readabilityPanel':e[flag]=False
  elif flag=='rotation':e[flag]=.2
  elif flag=='extraBacking':e['panels'].append({'rect':[50,50,20,20],'color':[255,255,255],'backing':True})
  elif flag=='clipped':e['panels'][0]['clipped']=True
  else:e[flag]=True
  add('balloon gate '+flag,[e])
 a=entry('a',[25,25,45,15],[20,20,60,30],demand=3,valid=False,source=[25,25,30,15]);b=entry('b',[80,60,50,15],[70,40,70,60],demand=3,valid=False,source=[80,60,30,15]);b['panels'][0]['color']=[0,0,0]
 add('foreign owner restores covered dark surface',[a,b],sourceColor=[0,0,0])
 add('foreign owner mismatch no repaint',[a,b],sourceColor=[180,80,40])
 a=entry('main with erasure',[50,55,60,15],[40,40,85,50]);a['panels'].insert(0,{'rect':[42,42,75,40],'color':[220,220,220],'erasure':True});a['panels'].append({'rect':[55,55,20,20],'color':[255,255,255],'backing':True})
 add('main retains all source erasure coverage',[a])
 many=[entry(str(i),[10+(i%24)*32,10+(i//24)*32,12,10],[8+(i%24)*32,8+(i//24)*32,24,24],font=8,demand=1) for i in range(513)]
 add('page measurement budget preserves last caption',many);fs[-1]['page']=[0,0,800,800]
 for i in range(100):
  es=[]
  for j in range(rng.randint(1,5)):
   x,y=rng.randrange(10,180),rng.randrange(10,180);w,h=rng.randrange(30,110),rng.randrange(25,100)
   es.append(entry(str(j),[x+5,y+5,w-10,15],[x,y,w,h],font=rng.choice([8,12,18]),demand=rng.choice([3,5,8,15]),valid=rng.random()>.1,source=[x+rng.randrange(-10,10),y+rng.randrange(-10,10),20,20]))
  add('group matrix '+str(i),es)
 return fs

def main():
 OUT.mkdir(parents=True,exist_ok=True);fs=fixtures();(OUT/'fixtures.json').write_text(json.dumps(fs))
 names=['NativeTranslationPixelKernels','NativeSourceColorSampler','NativeCSSCoveragePath', 'NativeTranslationSourceStylePostPolish','NativePanelGeometry','NativeCaptionPacking'];snapshot=OUT/'source';snapshot.mkdir(exist_ok=True);paths=[];digest=hashlib.sha256()
 for n in names:
  p=SRC/(n+'.swift');raw=p.read_bytes();target=snapshot/p.name;target.write_bytes(raw);paths.append(str(target));digest.update(raw)
 lib=ROOT/'build/native-overlay-kernels-host/libAidokuOverlayKernels.a';digest.update(str(lib.stat().st_mtime_ns).encode());raw=(HERE/'CaptionPackingParityMain.swift').read_bytes();(OUT/'main.swift').write_bytes(raw);digest.update(raw)
 cache=OUT/'build-hash';binary=OUT/'native'
 if not binary.exists() or not cache.exists() or cache.read_text()!=digest.hexdigest():
  subprocess.run(['swiftc','-swift-version','6','-O','-I',str(ROOT/'Scripts/overlay-kernels/native'),*paths,str(OUT/'main.swift'),str(lib),'-o',str(binary)],check=True);cache.write_text(digest.hexdigest())
 subprocess.run([str(binary),str(OUT/'fixtures.json'),str(OUT/'native.json')],check=True)
 browser=json.loads(subprocess.check_output(['node','-e',NODE,str(HERE/'reference-source')],input=json.dumps(fs).encode()));(OUT/'browser.json').write_text(json.dumps(browser));native=json.loads((OUT/'native.json').read_text())
 def eq(a,b):
  if isinstance(a,(int,float)) and not isinstance(a,bool) and isinstance(b,(int,float)) and not isinstance(b,bool):return abs(a-b)<=1e-8
  if type(a)!=type(b):return False
  if isinstance(a,dict):return a.keys()==b.keys() and all(eq(a[k],b[k]) for k in a)
  if isinstance(a,list):return len(a)==len(b) and all(eq(x,y) for x,y in zip(a,b))
  return a==b
 failures=[{'name':a['name'],'native':a,'browser':b} for a,b in zip(native,browser) if not eq(a,b)];report={'fixtures':len(fs),'passed':len(fs)-len(failures),'failed':failures,'scope':'Full actual unified caption packing caller frozen body; identical physical glyph probes; independent typography/native pixel proof separately'}
 (OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps({'fixtures':len(fs),'passed':report['passed'],'failed':[x['name'] for x in failures][:20]}));raise SystemExit(bool(failures))
if __name__=='__main__':main()
