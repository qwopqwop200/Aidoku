#!/usr/bin/env python3
"""Differential of frozen late cohortSnap orchestration; identical layout callbacks."""
from pathlib import Path
import json,random,subprocess,hashlib
root=Path(__file__).resolve().parents[3];out=root/'build/native-render-parity/cohort-snap';out.mkdir(parents=True,exist_ok=True)
source=(root/'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift').read_text()
a=source.index('            const cohorts=snapRecords.length>256?');b=source.index('            // Late whole-word repair:',a);body=source[a:b]
rng=random.Random(9728);fixtures=[]
for t in range(320):
 n=2+t%5; members=[]
 for i in range(n):
  vertical=t%2==0;font=[5,7,8.5,9,10.25,12][(i+t)%6];line=8+(i%3)*.5
  sourcebox=[20+i*(10 if vertical else 24),40+i*(24 if vertical else 0),10 if vertical else 20,20 if vertical else 10]
  r=[sourcebox[0]-3,sourcebox[1]-3,24,28]
  owner=[r[0]-10,r[1]-10,44,48]
  if t%7==0:owner=[r[0],r[1],24,28]
  members.append(dict(id=str(i),source=sourcebox,vertical=vertical,glyph=8,line=line,font=font,base=5 if t%3 else None,
   readablePeer=5 if t%9==0 else None,condensedFrom=font-1 if t%8==0 else None,key=('v' if vertical else 'h')+'|'+('other' if i==n-1 and t%4==0 else 'dark'),
   node=dict(font=font,rect=r,owner=owner,alpha=1 if t%11==0 else 0,align=['left','right','center'][t%3],children=['word block','second'],tracking=-.012*font,forceReject=t%13==0,peer=5 if t%9==0 else None)))
 fixtures.append(dict(members=members,rowGroups=[list(range(n))] if t%3==0 else []))
(out/'fixtures.json').write_text(json.dumps(fixtures))
js=r'''const fs=require('fs');const fixtures=JSON.parse(fs.readFileSync(process.argv[2]));const output=fixtures.map(f=>{
 const snapRecords=f.members.map((m,i)=>({...m,x:m.source[0],y:m.source[1],w:m.source[2],h:m.source[3],base:m.base??Infinity,node:JSON.parse(JSON.stringify({...m.node,dataset:{readablePeer:m.readablePeer,condensedWidth:m.condensedFrom?`${m.condensedFrom}->${m.font}`:''}}))}));
 const aidokuReadableMinimum=8.5;let cohortSnapHeld=0,cohortSnaps=0,cohortSnapCondensed=0;
 const fontOf=m=>m.node.font,spread=v=>Math.max(...v)/Math.min(...v);
 const harmonyMembers=snapRecords,harmonyGroups=f.rowGroups.map(members=>({members}));
 const aidokuStyleGroups=(values,compatible,compare)=>{const groups=[];for(const v of [...values].sort(compare)){const g=groups.find(g=>g.every(o=>compatible(v,o)));if(g)g.push(v);else groups.push([v]);}return groups;};
 const snapshot=n=>JSON.parse(JSON.stringify(n)),restoreSnapshot=(n,s)=>{for(const k of Object.keys(n))delete n[k];Object.assign(n,JSON.parse(JSON.stringify(s)));};
 const clearance=n=>Math.min(n.rect[0]-n.owner[0],n.rect[1]-n.owner[1],n.owner[0]+n.owner[2]-n.rect[0]-n.rect[2],n.owner[1]+n.owner[3]-n.rect[1]-n.rect[3]);
 const inconsistent=()=>{let n=0;for(let i=0;i<snapRecords.length;i++)for(let j=i+1;j<snapRecords.length;j++){const a=snapRecords[i],b=snapRecords[j];if(spread([a.glyph,b.glyph])>1.15&&spread([a.w,b.w])>1.15&&spread([a.h,b.h])>1.15)continue;if(spread([fontOf(a),fontOf(b)])>1.25)n++;}return n;};
 const readablePeerFont=(n,font)=>n.dataset.readablePeer>0?Math.min(font,n.dataset.readablePeer):font;
 const readableHeld=m=>m.node.dataset.readablePeer?Math.min(fontOf(m),8.5):0;
 const condensedFloor=(m,size)=>{const from=Number((m.node.dataset.condensedWidth||'').split('->')[0]);if(!(from>0))return size;const floor=Math.ceil(from*1.06*4)/4;if(size<floor-.01){cohortSnapHeld++;m.node.dataset.cohortSnapHeld=`${size}->${floor}`;return floor;}return size;};
 const scaleTo=(m,size)=>{const n=m.node,k=size/n.font,r=n.rect,b=n.owner;const old=[...r];n.font=size;n.tracking*=k;n.rect=[r[0]+r[2]*(1-k)/2,r[1]+r[3]*(1-k)/2,r[2]*k,r[3]*k];if(n.forceReject){n.align='mutated';n.children=['mutated'];return false;}if(n.alpha>.01&&k>1)return false;const after=n.rect;if(k<=1)return after[0]>=old[0]-1&&after[1]>=old[1]-1&&after[0]+after[2]<=old[0]+old[2]+1&&after[1]+after[3]<=old[1]+old[3]+1;return after[0]>=b[0]&&after[1]>=b[1]&&after[0]+after[2]<=b[0]+b[2]&&after[1]+after[3]<=b[1]+b[3];};
'''+body+'''
 return {nodes:snapRecords.map(m=>({font:m.node.font,rect:m.node.rect,align:m.node.align,children:m.node.children,tracking:m.node.tracking})),changed:snapRecords.map((m,i)=>Math.abs(fontOf(m)-m.font)>.01?[i,m.font,fontOf(m)]:null).filter(Boolean),rows:sourceRows.map(g=>g.map(m=>snapRecords.indexOf(m)))};
});console.log(JSON.stringify(output));'''
(out/'oracle.cjs').write_text(js);p=subprocess.run(['node',str(out/'oracle.cjs'),str(out/'fixtures.json')],text=True,capture_output=True);assert p.returncode==0,p.stderr;expected=json.loads(p.stdout);(out/'expected.json').write_text(json.dumps(expected))
main=r'''import CoreGraphics
import Foundation
struct Node {var font:CGFloat;var rect:CGRect;var owner:CGRect;var alpha:CGFloat;var align:String;var children:[String];var tracking:CGFloat;var forceReject:Bool}
@main struct Main {static func main() throws {
 let raw=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
 func num(_ x:Any?)->CGFloat {CGFloat((x as? NSNumber)?.doubleValue ?? 0)}
 func rect(_ x:Any?)->CGRect {let a=x as! [NSNumber];return CGRect(x:num(a[0]),y:num(a[1]),width:num(a[2]),height:num(a[3]))}
 var output:[[String:Any]]=[]
 for f in raw {
 let a=f["members"] as! [[String:Any]]
 var nodes=a.map {m->Node in let n=m["node"] as! [String:Any];return .init(font:num(n["font"]),rect:rect(n["rect"]),owner:rect(n["owner"]),alpha:num(n["alpha"]),align:n["align"] as! String,children:n["children"] as! [String],tracking:num(n["tracking"]),forceReject:n["forceReject"] as! Bool)}
 let members=a.map {m->NativeTypographyCohortSnap.Member in .init(id:m["id"] as! String,source:rect(m["source"]),vertical:m["vertical"] as! Bool,glyph:num(m["glyph"]),line:num(m["line"]),font:num(m["font"]),base:m["base"] is NSNull ? .infinity:num(m["base"]),readablePeer:m["readablePeer"] is NSNull ? .infinity:num(m["readablePeer"]),readableHeld:m["readablePeer"] is NSNull ? 0:1,condensedFrom:m["condensedFrom"] is NSNull ? nil:num(m["condensedFrom"]),key:m["key"] as! String)}
 func spread(_ values:[CGFloat])->CGFloat {(values.max() ?? 0)/(values.min() ?? 0)}
 func clearance(_ i:Int)->CGFloat {let r=nodes[i].rect,b=nodes[i].owner;return min(r.minX-b.minX,r.minY-b.minY,b.maxX-r.maxX,b.maxY-r.maxY)}
 func inconsistent()->Int {var count=0;for i in members.indices {for j in members.indices where j>i {let a=members[i],b=members[j];if spread([a.glyph,b.glyph])>1.15 && spread([a.source.width,b.source.width])>1.15 && spread([a.source.height,b.source.height])>1.15 {continue};if spread([nodes[i].font,nodes[j].font])>1.25{count+=1}}};return count}
 let result=NativeTypographyCohortSnap.snap(members:members,rowGroups:f["rowGroups"] as! [[Int]],font:{nodes[$0].font},clearance:clearance,inconsistent:inconsistent,snapshot:{nodes[$0]},restore:{nodes[$0]=$1},scale:{i,size in
  let before=nodes[i].rect,k=size/nodes[i].font
  nodes[i].font=size;nodes[i].tracking*=k
  nodes[i].rect=CGRect(x:before.minX+before.width*(1-k)/2,y:before.minY+before.height*(1-k)/2,width:before.width*k,height:before.height*k)
  if nodes[i].forceReject{nodes[i].align="mutated";nodes[i].children=["mutated"];return false}
  if nodes[i].alpha>0.01 && k>1{return false}
  return k<=1 ? before.insetBy(dx:-1,dy:-1).contains(nodes[i].rect):nodes[i].owner.contains(nodes[i].rect)
 })
 output.append(["nodes":nodes.map { ["font":Double($0.font),"rect":[$0.rect.minX,$0.rect.minY,$0.rect.width,$0.rect.height],"align":$0.align,"children":$0.children,"tracking":Double($0.tracking)] },"changed":result.changed.keys.sorted().map { [Double($0)]+result.changed[$0]!.map(Double.init) },"rows":result.sourceRows])
 }
 print(String(data:try JSONSerialization.data(withJSONObject:output),encoding:.utf8)!)
}}
'''
(out/'Main.swift').write_text(main);policy=root/'Scripts/native-render-parity/NativeTypographyCohortSnap.swift';p=subprocess.run(['xcrun','swiftc','-swift-version','6',str(policy),str(out/'Main.swift'),'-o',str(out/'tests')],text=True,capture_output=True);(out/'typecheck.log').write_text(p.stderr);assert p.returncode==0,p.stderr
p=subprocess.run([str(out/'tests'),str(out/'fixtures.json')],text=True,capture_output=True);assert p.returncode==0,p.stderr;actual=json.loads(p.stdout);(out/'actual.json').write_text(json.dumps(actual))
def equal(a,b):
 if isinstance(a,(float,int)) and isinstance(b,(float,int)):return abs(a-b)<1e-10
 if type(a)!=type(b):return False
 if isinstance(a,dict):return a.keys()==b.keys() and all(equal(a[k],b[k]) for k in a)
 if isinstance(a,list):return len(a)==len(b) and all(equal(x,y) for x,y in zip(a,b))
 return a==b
fail=[i for i,(a,b) in enumerate(zip(expected,actual)) if not equal(a,b)]
report=dict(cases=len(fixtures),equal=len(fixtures)-len(fail),failures=fail,policySHA256=hashlib.sha256(policy.read_bytes()).hexdigest(),scope='Frozen late cohortSnap whole orchestration and production-staged Swift policy. Identical injected transparent-owner/painted-self scale, clearance and page inconsistency callbacks; full inherited node state rollback is compared. Floating host arithmetic compared within1e-10; no final raster or platform adapter claim. Membership capture and real Card adapter remain pending.')
(out/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report));assert not fail
