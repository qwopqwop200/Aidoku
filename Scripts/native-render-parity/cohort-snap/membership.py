#!/usr/bin/env python3
from pathlib import Path
import json,subprocess,hashlib
root=Path(__file__).resolve().parents[3];out=root/'build/native-render-parity/cohort-snap-membership';out.mkdir(parents=True,exist_ok=True)
source=(root/'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift').read_text();a=source.index('            const snapRecords=[];',source.index('let cohortSnaps='));b=source.index('            const cohorts=',a);body=source[a:b]
fixtures=[]
texts=['검증문','日本語','Abc','9','Ⅷ','½','ᵃ','!!!','♡',' ','\n','\u0301']
for t in range(240):
 flags={key:False for key in ['rotation','nearRotation','sourceRotation','hidden','displayGrowth','rotatingPanel']}
 if t%5==0: flags[list(flags)[t//5%6]]=True
 f=dict(id=str(t),text=texts[t%len(texts)],bounds=[.1,.2,.08,.16],frame=[2,3,200,300],glyph=[0,8,40,12][t%4],font=[0,5,8.5][t%3],vertical=t%2==0,automatic=t%17!=0,**flags,
    sampledInk=[[0,0,0],[70,69,134],[255,260,0],None][t%4],sampledBackground=[[250,250,250],[42,55,44],None][t%3],appliedBackground=[[128,162,154],[0,60,255],None][t%3],outlined=t%3==0,growthFonts=[6,8.5] if t%7 else [],readablePeer=0 if t%5==1 else 5 if t%5==2 else None,condensedFrom=7 if t%7==2 else None)
 if t%29==0:f['bounds']=None
 if t%31==0:f['frame']=None
 fixtures.append(f)
# Active deterministic cases cover every Unicode L/N type, thickness/glyph fallback and label class.
for i,text in enumerate(texts):
 f=dict(fixtures[1]);f.update(id='unicode'+str(i),text=text,glyph=12,font=8.5,automatic=True,rotation=False,nearRotation=False,sourceRotation=False,hidden=False,displayGrowth=False,rotatingPanel=False,bounds=[.1,.2,.04,.03],frame=[2,3,200,300]);fixtures.append(f)
(out/'fixtures.json').write_text(json.dumps(fixtures,ensure_ascii=False))
js=r'''const fs=require('fs'),input=JSON.parse(fs.readFileSync(process.argv[2]));
const aidokuStyleColorClass=rgb=>{if(!Array.isArray(rgb)||rgb.length<3||!rgb.slice(0,3).every(v=>Number.isFinite(v)&&v>=0&&v<=255))return '?';const [r,g,b]=rgb.slice(0,3).map(v=>v/255),max=Math.max(r,g,b),min=Math.min(r,g,b);if((max-min)*255>60){const h=max===r?((g-b)/(max-min)+6)%6:max===g?(b-r)/(max-min)+2:(r-g)/(max-min)+4;return 'h'+Math.floor(((h*60+30)%360)/60);}const l=.299*r+.587*g+.114*b;return l<.3?'dark':l>.72?'light':'mid';};
console.log(JSON.stringify(input.map(f=>{const item={id:f.id,text:f.text,sourceBounds:f.bounds,sourceFrame:f.frame,sourceVertical:f.vertical,rotation:f.rotation,nearUprightRotation:f.nearRotation,allowsAutomaticFontRecovery:f.automatic};const data={sourceRotation:f.sourceRotation?'true':'',displayGrowth:f.displayGrowth?'true':'',rotatingPanel:f.rotatingPanel?'true':'false',sourceSampledTextRGB:f.sampledInk?.join(',')||'',sourceSampledBackgroundRGB:f.sampledBackground?.join(',')||'',sourceAppliedBackgroundRGB:f.appliedBackground?.join(',')||'',sourceTextOutline:String(f.outlined)};const nodes=[{item,dataset:data,style:{fontSize:String(f.font),visibility:f.hidden?'hidden':'visible'}}];const itemFor=n=>n.item;const cleanupImageGeometry=null;const sourceGlyph=()=>f.glyph;const grownFrom=()=>f.growthFonts.length?Math.min(...f.growthFonts):Infinity;
'''+body.replace('/[^\\\\p{L}\\\\p{N}]/gu','/[^\\p{L}\\p{N}]/gu')+'''
return snapRecords.map(m=>({id:m.id,source:[m.x,m.y,m.w,m.h],vertical:m.vertical,glyph:m.glyph,line:m.line,font:m.font,base:Number.isFinite(m.base)?m.base:null,key:m.key}));})));'''
(out/'oracle.cjs').write_text(js);p=subprocess.run(['node',str(out/'oracle.cjs'),str(out/'fixtures.json')],text=True,capture_output=True);assert p.returncode==0,p.stderr;expected=json.loads(p.stdout)
main=r'''import Foundation
import CoreGraphics
@main struct Main {static func main() throws {
let input=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
func n(_ v:Any?)->CGFloat {CGFloat((v as? NSNumber)?.doubleValue ?? 0)}
func numbers(_ v:Any?)->[CGFloat]? {(v as? [NSNumber])?.map { CGFloat($0.doubleValue) }}
var output:[[[String:Any]]]=[]
for f in input {
 let a=NativeTypographyCohortSnap.Input(id:f["id"] as! String,text:f["text"] as! String,bounds:numbers(f["bounds"]),frame:numbers(f["frame"]),glyph:n(f["glyph"]),font:n(f["font"]),vertical:f["vertical"] as! Bool,rotation:f["rotation"] as! Bool,nearRotation:f["nearRotation"] as! Bool,sourceRotation:f["sourceRotation"] as! Bool,hidden:f["hidden"] as! Bool,automatic:f["automatic"] as! Bool,displayGrowth:f["displayGrowth"] as! Bool,rotatingPanel:f["rotatingPanel"] as! Bool,sampledInk:numbers(f["sampledInk"])?.map(Double.init),sampledBackground:numbers(f["sampledBackground"])?.map(Double.init),appliedBackground:numbers(f["appliedBackground"])?.map(Double.init),outlined:f["outlined"] as! Bool,growthFonts:numbers(f["growthFonts"])!,readablePeer:f["readablePeer"] is NSNull ? nil:n(f["readablePeer"]),condensedFrom:f["condensedFrom"] is NSNull ? nil:n(f["condensedFrom"]))
 if let m=NativeTypographyCohortSnap.capture(a) {output.append([["id":m.id,"source":[m.source.minX,m.source.minY,m.source.width,m.source.height],"vertical":m.vertical,"glyph":m.glyph,"line":m.line,"font":m.font,"base":m.base.isFinite ? Double(m.base) as Any:NSNull(),"key":m.key]])} else {output.append([])}
}
print(String(data:try JSONSerialization.data(withJSONObject:output),encoding:.utf8)!)
}}
'''
(out/'Main.swift').write_text(main);policy=root/'Scripts/native-render-parity/NativeTypographyCohortSnap.swift';p=subprocess.run(['xcrun','swiftc','-swift-version','6',str(policy),str(out/'Main.swift'),'-o',str(out/'tests')],text=True,capture_output=True);assert p.returncode==0,p.stderr;p=subprocess.run([str(out/'tests'),str(out/'fixtures.json')],text=True,capture_output=True);assert p.returncode==0,p.stderr;actual=json.loads(p.stdout);fail=[i for i,(a,b) in enumerate(zip(expected,actual)) if a!=b]
(out/'expected.json').write_text(json.dumps(expected));(out/'actual.json').write_text(json.dumps(actual));report=dict(cases=len(fixtures),exact=len(fixtures)-len(fail),failures=fail,active=sum(bool(a) for a in expected),policySHA256=hashlib.sha256(policy.read_bytes()).hexdigest(),scope='Verbatim frozen late cohortSnap membership capture, Unicode L/N text gates, style key, source thickness, numeric floors and optional geometry, compared with staged native typed capture. No expensive initial admission substituted.');(out/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report));assert not fail
