#!/usr/bin/env python3
from pathlib import Path
import json,subprocess,random,hashlib
root=Path(__file__).resolve().parents[3];o=root/'Aidoku/Core/Translation/NativeEngine/Overlay';out=root/'build/native-render-parity/harmony-axis';out.mkdir(parents=True,exist_ok=True)
source=(root/'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift').read_text();start=source.index('          // Axis: along each shared line/column');end=source.index('          // Condensed width',start);body=source[start:end]
rng=random.Random(90319);fixtures=[]
for t in range(96):
 n=2+t%4;axis='x' if t%3==0 else 'y';edge=[0,.5,1][t%3];column=t%2==0
 members=[]
 for i in range(n):
  s={'x':i*30,'y':40 if column else i*3,'w':24+i*2,'h':80,'glyph':8,'script':'korean','vertical':column,'style':''};r=[s['x']+4,52+i*(6+t%13),15,6 if t%5==0 else 15]
  members.append({'source':s,'font':6+i*.25,'pitch':8,'r':r,'align':'center','limit':[-100,-100,500,300 if t%7 else 75]})
 links=[{'a':i,'b':i+1,'axis':axis,'edge':edge,'gap':3 if t%11 else 40} for i in range(n-1)]
 fixtures.append({'members':members,'groups':[] if column else [{'members':list(range(n)),'links':links}],'columns':links if column else []})
(out/'fixtures.json').write_text(json.dumps(fixtures))
js='''const fs=require('fs');const fixtures=JSON.parse(fs.readFileSync(process.argv[2]));const output=fixtures.map(f=>{
const harmonyMembers=f.members.map((m,i)=>({...m.source,node:{r:m.r,align:m.align,font:m.font,pitch:m.pitch,limit:m.limit,style:{},children:[],dataset:{}},item:{},id:String(i)}));
const harmonyGroups=f.groups,columnLinks=f.columns;
const fontOf=m=>m.node.font;
const inkOf=node=>{const r=node.r,dx=node.align==='left'?-2:node.align==='right'?2:0;return {left:r[0]+dx,top:r[1],width:r[2],height:r[3],right:r[0]+dx+r[2],bottom:r[1]+r[3]}};
const getComputedStyle=node=>({display:'flex',lineHeight:String(node.pitch),writingMode:'horizontal-tb'});
const snapshot=node=>JSON.parse(JSON.stringify(node));const restoreSnapshot=(node,s)=>{Object.assign(node,JSON.parse(JSON.stringify(s)))};
const shift=(node,dx,dy)=>{node.r[0]+=dx;node.r[1]+=dy};
const safeAt=(m,before)=>{if(m.node.style.textAlign)m.node.align=m.node.style.textAlign;const r=inkOf(m.node),b=m.node.limit;return r.left>=b[0]&&r.top>=b[1]&&r.right<=b[0]+b[2]&&r.bottom<=b[1]+b[3]};
let aligned=0;
'''+body+'''
return harmonyMembers.map(m=>({r:m.node.r,align:m.node.align}));});console.log(JSON.stringify(output));'''
(out/'oracle.cjs').write_text(js);p=subprocess.run(['node',str(out/'oracle.cjs'),str(out/'fixtures.json')],capture_output=True,text=True);assert p.returncode==0,p.stderr;expected=json.loads(p.stdout)
post=(o/'NativeTypographyPostPolish.swift').read_text();types=post[post.index('    struct SourceBox:'):post.index('    struct Profile:')]
(out/'Models.swift').write_text('import CoreGraphics\nimport Foundation\nenum NativeTypographyPostPolish {\n'+types+'\n}\n')
main=r'''import Foundation
import CoreGraphics
struct Node {var r:CGRect;var align:String;let limit:CGRect}
@main struct Main {static func main() throws {
let input=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
func number(_ a:Any?)->CGFloat {CGFloat((a as? NSNumber)?.doubleValue ?? 0)}
func rect(_ a:Any?)->CGRect {let v=a as! [NSNumber];return CGRect(x:v[0].doubleValue,y:v[1].doubleValue,width:v[2].doubleValue,height:v[3].doubleValue)}
func link(_ a:[String:Any])->NativeTypographyPostPolish.Link {.init(a:(a["a"] as! Int),b:(a["b"] as! Int),axis:a["axis"] as! String,edge:number(a["edge"]),gap:number(a["gap"]))}
var output:[[[String:Any]]]=[]
for f in input {
 let raw=f["members"] as! [[String:Any]]
 var nodes=raw.map {Node(r:rect($0["r"]),align:$0["align"] as! String,limit:rect($0["limit"]))}
 let members=raw.map {a->NativeTypographyHarmonyAxis.Member? in let s=a["source"] as! [String:Any];return .init(source:.init(x:number(s["x"]),y:number(s["y"]),w:number(s["w"]),h:number(s["h"]),glyph:number(s["glyph"]),script:s["script"] as! String,vertical:s["vertical"] as! Bool,style:s["style"] as! String),font:number(a["font"]),pitch:number(a["pitch"]))}
 let groups=(f["groups"] as! [[String:Any]]).map {NativeTypographyPostPolish.AlignedGroup(members:$0["members"] as! [Int],links:($0["links"] as! [[String:Any]]).map(link))}
 func ink(_ i:Int)->CGRect {nodes[i].r.offsetBy(dx:nodes[i].align == "left" ? -2:nodes[i].align == "right" ? 2:0,dy:0)}
 _=NativeTypographyHarmonyAxis.align(members:members,groups:groups,columnLinks:(f["columns"] as! [[String:Any]]).map(link),ink:ink,snapshot:{nodes[$0]},restore:{nodes[$0]=$1},flush:{i,e in let old=nodes[i];nodes[i].align=e == 0 ? "left":"right";if nodes[i].limit.contains(ink(i)){return true};nodes[i]=old;return false},move:{i,dx,dy in let old=nodes[i];nodes[i].r=nodes[i].r.offsetBy(dx:dx,dy:dy);if nodes[i].limit.contains(ink(i)){return true};nodes[i]=old;return false})
 output.append(nodes.map {["r":[$0.r.minX,$0.r.minY,$0.r.width,$0.r.height],"align":$0.align]})
}
print(String(data:try JSONSerialization.data(withJSONObject:output),encoding:.utf8)!)
}}
'''
(out/'Main.swift').write_text(main);p=subprocess.run(['xcrun','swiftc','-swift-version','6',str(out/'Models.swift'),str(o/'NativeTypographyHarmonyAxis.swift'),str(out/'Main.swift'),'-o',str(out/'tests')],capture_output=True,text=True);(out/'typecheck.log').write_text(p.stderr);assert p.returncode==0,p.stderr
p=subprocess.run([str(out/'tests'),str(out/'fixtures.json')],capture_output=True,text=True);assert p.returncode==0,p.stderr;actual=json.loads(p.stdout)
failures=[i for i,(a,b) in enumerate(zip(expected,actual)) if a!=b];report={'cases':len(fixtures),'exact':len(fixtures)-len(failures),'failures':failures,'scope':'Actual frozen whole row/column axis orchestration against production native pure policy, identical injected ink/owner query callbacks; rendering adapter is separately tested.','nativeSHA256':hashlib.sha256((o/'NativeTypographyHarmonyAxis.swift').read_bytes()).hexdigest()};(out/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report));assert not failures
