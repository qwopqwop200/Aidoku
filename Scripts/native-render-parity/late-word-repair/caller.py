#!/usr/bin/env python3
from pathlib import Path
import subprocess,json,hashlib
root=Path(__file__).resolve().parents[3];out=root/'build/native-render-parity/late-word-repair/caller';out.mkdir(parents=True,exist_ok=True)
s=(root/'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift').read_text();a=s.index('            (()=>{for(const m of snapRecords){',s.index('// Late whole-word repair:'));b=s.index('            if(lateRepairs)',a);body=s[a:b]
fixtures=[dict(members=['0','1','2'],rows=[['0','1']],sourceRows=[['1','2']],initial=[0,0,0],deltas=d,missing=missing,throwID=throw) for d,missing,throw in [([-1,-1,-1],[],None),([1,0,-1],[],None),([0,1,0],[],None),([0,0,0],['1'],None),([0,0,0],[],'0'),([-1,1,-1],[],'1')]]
(out/'fixtures.json').write_text(json.dumps(fixtures))
js=r'''const fs=require('fs'),fixtures=JSON.parse(fs.readFileSync(process.argv[2]));console.log(JSON.stringify(fixtures.map(f=>{
 const nodes=f.members.map(id=>({id})),snapRecords=nodes.map(node=>({id:node.id,node})),state=[...f.initial],attempts=[],accepted=[];let lateRepairs=0;
 const rowGroups=f.rows.map(ids=>ids.map(id=>({node:nodes.find(n=>n.id===id)}))),sourceRows=f.sourceRows.map(ids=>ids.map(id=>({node:nodes.find(n=>n.id===id)})));
 const inconsistent=()=>state.reduce((a,b)=>a+b,0),rowMismatch=rows=>rows.reduce((sum,row)=>sum+row.reduce((n,m)=>n+state[Number(m.node.id)],0),0);
 const typographyEntries=nodes.filter(n=>!f.missing.includes(n.id)).map(node=>({id:node.id,repairWords:(late,accept)=>{attempts.push(node.id);if(node.id===f.throwID)throw Error('trial');const old=state[+node.id];state[+node.id]+=f.deltas[+node.id];if(!accept()){state[+node.id]=old;return false;}accepted.push(node.id);return true;}}));
'''+body+'''return {count:lateRepairs,state,attempts,accepted};})));
'''
(out/'oracle.cjs').write_text(js)
p=subprocess.run(['node',str(out/'oracle.cjs'),str(out/'fixtures.json')],capture_output=True,text=True);assert p.returncode==0,p.stderr;expected=json.loads(p.stdout)
main=r'''import Foundation
import CoreGraphics
struct TrialError: Error {}
@main struct Main {static func main() throws {
 let fs=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]];var output:[[String:Any]]=[]
 for f in fs {let ids=f["members"] as! [String],rows=f["rows"] as! [[String]],source=f["sourceRows"] as! [[String]],missing=f["missing"] as! [String],deltas=f["deltas"] as! [Int];var state=f["initial"] as! [Int],attempts:[String]=[],accepted:[String]=[]
 let count=NativeLateWordRepair.afterCohort(members:ids,harmonyRows:rows,sourceRows:source,pageConflicts:{state.reduce(0,+)},rowConflicts:{groups in groups.reduce(0){sum,row in sum+row.reduce(0){$0+state[Int($1)!]}}},repair:{id,accept in
 guard !missing.contains(id) else{return false};attempts.append(id);if id==f["throwID"] as? String{throw TrialError()};let i=Int(id)!,old=state[i];state[i]+=deltas[i];guard accept() else{state[i]=old;return false};accepted.append(id);return true
 });output.append(["count":count,"state":state,"attempts":attempts,"accepted":accepted])
 };print(String(data:try JSONSerialization.data(withJSONObject:output),encoding:.utf8)!)
}}
'''
(out/'Main.swift').write_text(main);helper=root/'Scripts/native-render-parity/late-word-repair/NativeLateWordRepair.swift'
p=subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(helper),str(out/'Main.swift'),'-o',str(out/'runner')],capture_output=True,text=True);assert p.returncode==0,p.stderr
p=subprocess.run([str(out/'runner'),str(out/'fixtures.json')],capture_output=True,text=True);assert p.returncode==0,p.stderr;actual=json.loads(p.stdout)
report=dict(cases=len(fixtures),passed=sum(a==b for a,b in zip(actual,expected)),expected=expected,actual=actual,helperSHA256=hashlib.sha256(helper.read_bytes()).hexdigest(),scope='Original late caller extracted verbatim; dynamic page and combined harmony/source row consistency, rollback, absent entries and throwing-entry isolation.')
(out/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report));assert actual==expected
