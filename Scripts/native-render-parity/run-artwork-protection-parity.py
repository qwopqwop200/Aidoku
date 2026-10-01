#!/usr/bin/env python3
import json,pathlib,subprocess,random
ROOT=pathlib.Path(__file__).resolve().parents[2];HERE=pathlib.Path(__file__).resolve().parent;OUT=ROOT/'build/native-render-parity/artwork-protection'
NODE=r'''
const fs=require('fs'),vm=require('vm'),base=process.argv[1],fixtures=JSON.parse(fs.readFileSync(0,'utf8'));
const view=fs.readFileSync(base+'/BrowserOverlayView.swift','utf8'),a=view.indexOf('protectArtwork: () => {'),b=view.indexOf('            // A complete restoration without small surviving lettering',a);
const body=view.slice(a+'protectArtwork: () => {'.length,b).trim().replace(/\},$/u,'').replaceAll('\\\\','\\');
const typography=fs.readFileSync(base+'/BrowserOverlayTypography.swift','utf8').split('static let script = #"""')[1].split('"""#')[0];
const c=vm.createContext({});vm.runInContext(typography,c);
vm.runInContext(`globalThis.run=f=>{
 const font=f.font??14,minimumFontSize=f.minimum??5,displayedText=f.text??'HELLO WORDS',wrappingScript=f.rtl?'rightToLeft':'korean',artworkFirst=f.enabled!==false;
 let artworkTypeBudget=f.type??8192,artworkProbePixels=f.probe??32768,artworkSurfaceBudget=f.surface??1048576,restoredPanelLookupBudget=4194304,lookupOwner='panel',readabilityPanels=1,callbacks=0,x=20,y=20,width=100,height=60;
 const box={left:20,top:20,right:120,bottom:80,width:100,height:60};
 const originalChildren=[{textContent:displayedText,cloneNode(){return {...this}}}];
 function makeNode(){const style={left:'20px',top:'20px',width:'100px',height:'60px',fontSize:font+'px',lineHeight:font*1.2+'px'};
 Object.defineProperty(style,'cssText',{get(){return JSON.stringify(Object.fromEntries(Object.entries(this).filter(([k])=>k!=='cssText')))},set(v){Object.assign(this,JSON.parse(v))}});
 return {style,dataset:{},childNodes:originalChildren,replaceChildren(...cs){this.childNodes=cs},remove(){}};}
 const node1=makeNode(),node2=makeNode(),measurementNode=node2;
 const item={id:f.name,balancedColumn:!!f.balanced,rotation:f.rotation??0,sourceBounds:[.11,.06,.06,.07],sourceFrame:[0,0,500,500],sourceFontSize:font};
 const otherSource={sourceBounds:[.08,.05,.04,.04],sourceFrame:[0,0,500,500]};const items=f.sharedSource?[item,otherSource]:[item];
 const restoredSourcePanels=new Set(f.restored?[item]:[]),captionTextReflows=new Map([[item,()=>{}]]),sampled={};
 const panelGeometry={erasureComplete:!!f.complete,residualLettering:!!f.residual};
 const plate={dataset:{aidokuRegion:f.name},getBoundingClientRect:()=>box,remove(){}},otherNode={};
 const root={querySelectorAll(selector){if(selector.includes('source-readability-panel'))return f.plate===false?[]:[plate];return f.sharedText?[node1,otherNode]:[node1];}};
 const document={createRange:()=>({selectNodeContents(){},getBoundingClientRect:()=>({left:40,top:25,width:20,height:20})}),createElement:()=>({style:{},textContent:''})},measurementHost={appendChild(){}},scrollX=0,scrollY=0;
 const sourceImage=f.image===false?null:{complete:true,naturalWidth:500,naturalHeight:500},cleanupImageGeometry={frame:[0,0,500,500]},cleanupCanvas={};
 const cleanupContext={drawImage(){if(f.readFails)throw Error('read failed')},getImageData(){return {data:Uint8Array.from({length:4096},(_,i)=>{if(i%4===3)return f.alpha??255;const n=Math.floor(i/4),x=n%32,y=Math.floor(n/32),dark=f.solid||x<3||x>=29||y<3||y>=29;return dark?[40,60,80][i%4]:245;})}}};
 const aidokuCaptionPalette=()=>({background:[245,245,245]}),budgetStop=()=>true;
 const fitsRestoredSurface=f.surfaceQuery?(profile)=>{callbacks++;restoredPanelLookupBudget-=Math.min(restoredPanelLookupBudget,f.cost??1200);return !!f.surfaceAccept}:null;
 const applyMeasuredFontSize=size=>{for(const n of[node1,node2])n.style.fontSize=size+'px';},contentFits=()=>!f.overflows;
 const lineProfile=()=>{if(f.profile===false)return null;const size=parseFloat(node1.style.fontSize),k=size/font;
 if(size===font)return {lines:2,lineStarts:[0,6],breaks:[],badStarts:[],badEnds:[],hangulFragments:0,punctuationOnly:0,ink:[[20,20,100,60]]};
 return {lines:f.badLines?3:2,lineStarts:[0,6],breaks:f.badFlow?[1]:[],badStarts:[],badEnds:[],hangulFragments:0,punctuationOnly:0,ink:[[70-100*k/2+(f.shift??0),50-60*k/2,100*k,60*k]]};};
 const node=node1;
 const protect=()=>{${body}};protect();
 const accepted=!!node.dataset.artworkFit,out={name:f.name,accepted,type:artworkTypeBudget,probe:artworkProbePixels,surface:artworkSurfaceBudget,callbacks};
 if(accepted){out.font=parseFloat(node.style.fontSize);out.lines=node.childNodes.map(c=>c.textContent);out.released=node.dataset.artworkFit==='restored-surface';out.metadata=Object.fromEntries(Object.entries(node.dataset).filter(([k])=>['artworkFit','artworkOriginalFont','artworkOriginalInk','artworkFinalFont','artworkSourceErasure','artworkRiskBefore','artworkRiskAfter','sourcePanelFinalFont','sourcePanelTextFit','sourceBackgroundColor','sourceAppliedBackgroundRGB'].includes(k)));}
 return out;
};`,c);
process.stdout.write(JSON.stringify(fixtures.map(f=>c.run(f))));
'''
def fixtures():
 fs=[]
 def add(name,**kw):fs.append({'name':name,**kw})
 add('border art shrinks')
 add('solid art no safe shrink',solid=True)
 add('owned clean restoration releases',surfaceQuery=True,complete=True,surfaceAccept=True,image=False)
 add('shared source keeps plate',surfaceQuery=True,complete=True,surfaceAccept=True,sharedSource=True)
 add('shared text keeps plate',surfaceQuery=True,complete=True,surfaceAccept=True,sharedText=True)
 add('residual prevents release',surfaceQuery=True,complete=True,surfaceAccept=True,residual=True)
 add('unsafe surface risk fallback',surfaceQuery=True,complete=True,surfaceAccept=False)
 add('exhausted surface risk fallback',surfaceQuery=True,complete=True,surfaceAccept=True,surface=0)
 add('bounded surface lookup debit',surfaceQuery=True,complete=True,surfaceAccept=True,surface=500,cost=700,image=False)
 for k,v in [('balanced',True),('rotation',.1),('rtl',True),('restored',True),('text','A\nB'),('type',0),('font',5),('profile',False),('plate',False),('enabled',False),('probe',0),('image',False),('alpha',249),('badFlow',True),('badLines',True),('overflows',True),('shift',50),('readFails',True)]:add('gate '+k,**{k:v})
 rng=random.Random(5728)
 for i in range(100):add('matrix '+str(i),font=rng.choice([5.5,8,10,14,20,32]),minimum=rng.choice([5,7]),solid=rng.choice([False,False,True]),surfaceQuery=rng.random()<.5,complete=rng.random()<.7,surfaceAccept=rng.random()<.6,residual=rng.random()<.3,sharedSource=rng.random()<.3,sharedText=rng.random()<.2,alpha=rng.choice([249,250,255]),badFlow=rng.random()<.2,shift=rng.choice([0,0,3,30]))
 return fs

def main():
 OUT.mkdir(parents=True,exist_ok=True);fs=fixtures();(OUT/'fixtures.json').write_text(json.dumps(fs))
 subprocess.run(['swiftc','-swift-version','6','-O',str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeArtworkProtection.swift'),str(HERE/'ArtworkProtectionParityMain.swift'),'-o',str(OUT/'native')],check=True)
 subprocess.run([str(OUT/'native'),str(OUT/'fixtures.json'),str(OUT/'native.json')],check=True)
 js=subprocess.run(['node','-e',NODE,str(HERE/'reference-source')],input=json.dumps(fs),text=True,capture_output=True)
 if js.returncode:print(js.stderr);raise SystemExit(js.returncode)
 (OUT/'web.json').write_text(js.stdout);native=json.loads((OUT/'native.json').read_text());web=json.loads(js.stdout)
 def eq(a,b):
  if isinstance(a,(int,float)) and isinstance(b,(int,float)):return abs(a-b)<1e-7
  if isinstance(a,list) and isinstance(b,list):return len(a)==len(b) and all(eq(x,y) for x,y in zip(a,b))
  if isinstance(a,dict) and isinstance(b,dict):return a.keys()==b.keys() and all(eq(a[k],b[k]) for k in a)
  return a==b
 failures=[{'name':a['name'],'native':a,'web':b} for a,b in zip(native,web) if not eq(a,b)]
 report={'cases':len(fs),'passed':len(fs)-len(failures),'active':sum(x['accepted'] for x in native),'released':sum(x.get('released',False) for x in native),'failures':failures,'scope':'Actual frozen protectArtwork fullbody and borrowed original typography helpers with identical profile/actualpixel surface-query inputs; sourcerisk pixels32x32 realRGBA policies. Deterministic shaping and surface-query callbacks are shared inputs; actual font and source-safety adapters require separate validation.'}
 (OUT/'report.json').write_text(json.dumps(report,indent=2));print(f"{report['passed']}/{len(fs)} exact; {report['active']} protected, {report['released']} plate releases")
 if failures:print(json.dumps(failures[:2],indent=2));raise SystemExit(1)
if __name__=='__main__':main()
