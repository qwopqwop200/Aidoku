#!/usr/bin/env python3
from pathlib import Path
import json,subprocess,hashlib
root=Path(__file__).resolve().parents[3];out=root/'build/native-render-parity/late-word-repair/policy';out.mkdir(parents=True,exist_ok=True)
src=(root/'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift').read_text()
a=src.index('            repairWords: (late=false');b=src.index('            protectArtwork:',a)
body=src[a:b].strip().removesuffix(',').replace('repairWords:','const repairWords=',1).replace('\\\\','\\')
typ=(root/'Scripts/native-render-parity/reference-source/BrowserOverlayTypography.swift').read_text()
frame=typ[typ.index('    const aidokuCaptionInkFrame'):typ.index('    const aidokuCohortFontCandidates')]
word=typ[typ.index('    const aidokuKoreanWordWidth'):typ.index('    // Condensed Korean width')]
bad=typ[typ.index('    const aidokuMildBreakParticles'):typ.index('    // A caption that is only one reduplicated')]
base=json.loads((root/'build/native-render-parity/late-word-repair/native-counterexample.json').read_text())
fixtures=[]
for i in range(96):
 f=dict(font=9 if i==0 else [8,8.5,9,12,18][i%5],node=base['node'],ink=base['ink'],advance=base['advance'],
  bad=2,scale=False,veto=False,surface=True,type=8192,surfaceBudget=1048576,exterior=1048576,late=1048576,
  window=[0,0,200,200],safe=True,obstacles=[],shift=0,content=True,forceCondense=False,shrink=False)
 if i:
  mode=i%12
  if mode==1:f['veto']=True
  if mode==2:f['surface']=False
  if mode==3:f['scale']=True
  if mode==4:f['type']=5
  if mode==5:f['bad']=0
  if mode==6:f['forceCondense']=True
  if mode==7:f['shrink']=True
  if mode==8:f['obstacles']=[[0,0,200,200]]
  if mode==9:f['shift']=2
  if mode==10:f['surfaceBudget']=0
  if mode==11:f['content']=False
 fixtures.append(f)
# Two distinct centres with high original fonts exercise the literal 48-attempt cap.
for i in range(8):
 f=dict(fixtures[1]);f.update(font=18+i,ink=[60,69,15.354,32],veto=True,forceCondense=False,shrink=False)
 fixtures.append(f)
(out/'fixtures.json').write_text(json.dumps(fixtures))
js=r'''const fs=require('fs');const fixtures=JSON.parse(fs.readFileSync(process.argv[2]));
'''+frame+word+bad+r'''
const results=fixtures.map(f=>{
 const displayedText='검증합니다',root={querySelectorAll:q=>q.includes('item')?[]:f.obstacles.map(r=>({getBoundingClientRect:()=>rect(r)}))};
 const rect=r=>({left:r[0],top:r[1],right:r[0]+r[2],bottom:r[1]+r[3],width:r[2],height:r[3]});
 const mk=()=>{let values={};const style=new Proxy({}, {get:(o,k)=>k==='cssText'?JSON.stringify(values):values[k]??'',set:(o,k,v)=>{if(k==='cssText')values=JSON.parse(v);else values[k]=v;return true;}});
  const n={style,childNodes:[],dataset:{},parentElement:root,appendChild(c){this.childNodes.push(c)},replaceChildren(...c){this.childNodes=c},remove(){},cloneNode(){return {textContent:this.textContent,cloneNode:this.cloneNode}}};
  Object.defineProperty(n,'textContent',{set(v){this.childNodes=[];this.value=v},get(){return this.value||''}});return n;};
 const node=mk(),measurementNode=mk(),measurementHost={appendChild(){}};
 Object.assign(node.style,{left:'40px',top:'60px',width:'24px',height:'50px',fontSize:`${f.font}px`,fontWeight:'400',fontFamily:'oracle',scale:f.scale?'0.9 1':''});
 Object.assign(node.dataset,{sourceBackgroundColor:'inpainted',sourcePanelTextFit:'inside',sourceAppliedTextRGB:'0,0,0'});node.textContent=displayedText;
 const item={id:'late-gap',sourceBounds:[.2,.3,.12,.25],sourceFontSize:8},restoredSourcePanels=new Set([item]),wrappingScript='korean',koreanWrapMeasure=true;
 let x=40,y=60,width=24,height=50,scrollX=0,scrollY=0;
 const panelGeometry={frame:[0,0,200,200],x:f.window[0],y:f.window[1],w:f.window[2],h:f.window[3],sx:1,sy:1,iw:200,ih:200,surfaceQuality:{safe:f.safe}};
 let balloonTypeBudget=f.type,balloonSurfaceBudget=f.surfaceBudget,restoredExteriorPixelBudget=f.exterior,restoredPanelLookupBudget=777,lateWordRepairBudget=f.late,wordRepairBudget=1048576,lookupOwner='panel';
 const saved=node.style.cssText;let surfaceCalls=0,measureCalls=0,last=null;
 const aidokuCondensedWidth=.9,lineHeightRatio=1.2;
 const aidokuReduplicationBreak=()=>false,aidokuSourceColorLuminance=()=>0,budgetStop=()=>true;
 let currentFont=f.font;
 const setKoreanFont=font=>{currentFont=Number(font.split(' ')[1].replace('px',''))};
 const koreanTextWidth=()=>f.advance*currentFont/9;
 const aidokuKoreanLines=(text,w,maxLines,measure)=>measure(text)<=w+.25?[text]:null;
 const applyMeasuredFontSize=s=>{node.style.fontSize=measurementNode.style.fontSize=`${s}px`};
 const lineProfile=()=>{if(!node.childNodes.length)return {ink:[f.ink],breaks:f.bad?[2,4]:[],lines:3,hangulIsolated:0,hangulFragments:0,punctuationOnly:0,badStarts:[],badEnds:[]};
  const size=parseFloat(node.style.fontSize),k=node.style.scale?.startsWith('.9')||node.style.scale?.startsWith('0.9')?.valueOf()?0.9:1;
  const raw=f.advance*size/9+4*size*(-.012),cx=x+width/2,cy=y+height/2;
  last={ink:[[cx-raw*k/2+f.shift,cy-6,raw*k,12]],breaks:[],lines:1,hangulIsolated:0,hangulFragments:0,punctuationOnly:0,badStarts:[],badEnds:[]};measureCalls++;return last;};
 const contentFits=()=>f.content&&(!f.forceCondense||node.style.scale)&&(!f.shrink||parseFloat(node.style.fontSize)<f.font);
 const fitsRestoredSurface=()=>{surfaceCalls++;restoredPanelLookupBudget-=16;restoredExteriorPixelBudget-=7;return f.surface};
 const document={createElement:mk,createRange:()=>({selectNodeContents(){},getBoundingClientRect:()=>rect(last.ink[0])})};
'''+body+r'''
 const accepted=repairWords(true,()=>!f.veto);
 const result={accepted,node:[parseFloat(node.style.left),parseFloat(node.style.top),parseFloat(node.style.width),parseFloat(node.style.height)],font:parseFloat(node.style.fontSize),diagnostic:node.dataset.lateWordRepair?JSON.parse(node.dataset.lateWordRepair):null,spent:f.late-lateWordRepairBudget,type:balloonTypeBudget,surface:balloonSurfaceBudget,exterior:restoredExteriorPixelBudget,lookup:restoredPanelLookupBudget,surfaceCalls,measureCalls,restored:accepted?null:node.style.cssText===saved};return result;
});console.log(JSON.stringify(results));'''
(out/'oracle.cjs').write_text(js)
p=subprocess.run(['node',str(out/'oracle.cjs'),str(out/'fixtures.json')],capture_output=True,text=True);assert p.returncode==0,p.stderr
expected=json.loads(p.stdout);(out/'expected.json').write_text(json.dumps(expected))
main=r'''import Foundation
import CoreGraphics
@main struct Main {
 static func main() throws {
 let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
 func n(_ x:Any?)->Double {(x as? NSNumber)?.doubleValue ?? 0}
 func rect(_ x:Any)->CGRect {let a=x as! [NSNumber];return CGRect(x:a[0].doubleValue,y:a[1].doubleValue,width:a[2].doubleValue,height:a[3].doubleValue)}
 func array(_ r:CGRect)->[Double] {[r.minX,r.minY,r.width,r.height]}
 var output:[[String:Any]]=[]
 for f in fixtures {
 let font=n(f["font"]),originalRect=rect(f["node"]!), originalInk=rect(f["ink"]!)
 var node=originalRect, liveFont=font, hasRows=false,condense=1.0
 var budget=NativeLateWordRepair.Budget(late:Int(n(f["late"])),type:Int(n(f["type"])),surface:Int(n(f["surfaceBudget"])),exterior:Int(n(f["exterior"])),lookup:777)
 let profile=NativeLateWordRepair.Profile(ink:[originalInk],lines:3,splits:Int(n(f["bad"])),bad:Int(n(f["bad"])),isolated:0,fragments:0,punctuationOnly:0,badStarts:0,badEnds:0)
 var input=NativeLateWordRepair.Input(utf16Length:5,font:font,pitchRatio:1.2,sourceGlyph:8,source:CGRect(x:40,y:60,width:24,height:50),frame:CGRect(x:0,y:0,width:200,height:200),crop:rect(f["window"]!),sourceInkLuminance:0)
 input.hasScale=f["scale"] as! Bool;input.cropSafe=f["safe"] as! Bool;input.obstacles=(f["obstacles"] as! [[NSNumber]]).map{rect($0)}
 var surfaceCalls=0,measureCalls=0
 let result=NativeLateWordRepair.repair(input:input,original:profile,budget:&budget,snapshot:{(node,liveFont,hasRows,condense)},restore:{node=$0.0;liveFont=$0.1;hasRows=$0.2;condense=$0.3},wordWidth:{size in n(f["advance"])*size/9+4*size*(-0.012)+1},measure:{c in
  node=c.rect;liveFont=c.font;condense=c.condense;hasRows=false
  let raw=n(f["advance"])*c.font/9+4*c.font*(-0.012)
  guard raw<=c.rect.width+0.25 else{return nil};hasRows=true;measureCalls+=1
  let r=CGRect(x:c.anchor.x-raw*c.condense/2+n(f["shift"]),y:c.anchor.y-6,width:raw*c.condense,height:12)
  let candidate=NativeLateWordRepair.Profile(ink:[r],lines:1,splits:0,bad:0,isolated:0,fragments:0,punctuationOnly:0,badStarts:0,badEnds:0)
  let fits=(f["content"] as! Bool) && (!(f["forceCondense"] as! Bool)||c.condense<1) && (!(f["shrink"] as! Bool)||c.font<font)
  return .init(profile:candidate,contentFits:fits,live:r)
 },surface:{_,_,b in surfaceCalls+=1;b.lookup-=16;b.exterior-=7;return f["surface"] as! Bool},accept:{!(f["veto"] as! Bool)})
 output.append(["accepted":result != nil,"node":array(node),"font":liveFont,"diagnostic":result?.diagnostic as Any? ?? NSNull(),"spent":Int(n(f["late"]))-budget.late,"type":budget.type,"surface":budget.surface,"exterior":budget.exterior,"lookup":budget.lookup,"surfaceCalls":surfaceCalls,"measureCalls":measureCalls,"restored":result == nil ? (node==originalRect && liveFont==font) as Any:NSNull()])
 }
 print(String(data:try JSONSerialization.data(withJSONObject:output),encoding:.utf8)!)
 }
}'''
(out/'Main.swift').write_text(main)
helper=root/'Scripts/native-render-parity/late-word-repair/NativeLateWordRepair.swift'
p=subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(helper),str(out/'Main.swift'),'-o',str(out/'runner')],capture_output=True,text=True);assert p.returncode==0,p.stderr
p=subprocess.run([str(out/'runner'),str(out/'fixtures.json')],capture_output=True,text=True);assert p.returncode==0,p.stderr
actual=json.loads(p.stdout);(out/'actual.json').write_text(json.dumps(actual))
def same(a,b):
 if isinstance(a,(int,float)) and isinstance(b,(int,float)):return abs(a-b)<1e-8
 if isinstance(a,dict):return a.keys()==b.keys() and all(same(a[k],b[k]) for k in a)
 if isinstance(a,list):return len(a)==len(b) and all(same(x,y) for x,y in zip(a,b))
 return a==b
failed=[dict(index=i,expected=a,actual=b) for i,(a,b) in enumerate(zip(expected,actual)) if not same(a,b)]
report=dict(cases=len(fixtures),passed=len(fixtures)-len(failed),accepted=sum(x['accepted'] for x in actual),failures=failed,
 scope='Exact frozen repairWords late orchestration with identical injected profiles, Canvas widths, whole-word lines and surface query; full production macOS counterexample separately captured. No iOS pixels inferred.',
 helperSHA256=hashlib.sha256(helper.read_bytes()).hexdigest(),frozenSHA256=hashlib.sha256(src.encode()).hexdigest())
(out/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report));assert not failed
