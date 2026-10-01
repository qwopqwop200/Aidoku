import Foundation
import CoreGraphics
let input=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
func number(_ d:[String:Any],_ k:String,_ fallback:Double=0)->Double {(d[k] as? NSNumber)?.doubleValue ?? fallback}
func rect(_ a:[Double])->CGRect {CGRect(x:a[0],y:a[1],width:a[2],height:a[3])}
func box(_ r:CGRect)->[Double] {[Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)]}
var output:[[String:Any]]=[]
for f in input {
 let members=(f["members"] as! [[Double]]).map(rect),interior=rect(f["interior"] as! [Double]),isRoot=f["root"] as! Bool
 let e=NativeBalloonUnitParts.Entry(id:"a",text:f["text"] as! String,members:members,font:number(f,"font"),ratio:1.2,interiorSpan:number(f,"span",400),isRoot:isRoot,obstacles:(f["others"] as? [[Double]] ?? []).map(rect),panel:isRoot ? nil:rect(f["panel"] as! [Double]),coverage:(f["coverage"] as? [[Double]] ?? []).map(rect))
 let result=NativeBalloonUnitParts.place(e,measure:{text,frame,font,pitch in
  let words=text.split(separator:" ").map(String.init),advance=font*0.5
  var rows:[String]=[],row=""
  for word in words {let next=row.isEmpty ? word:row+" "+word;if !row.isEmpty && Double(next.utf16.count)*advance>Double(frame.width) {rows.append(row);row=word}else {row=next}}
  if !row.isEmpty {rows.append(row)}
  let lines=rows.enumerated().map {index,row in let width=Double(row.utf16.count)*advance
   return CGRect(x:Double(frame.midX)-width/2,y:Double(frame.midY)-Double(rows.count)*pitch/2+Double(index)*pitch+(pitch-font)/2,width:width,height:font)}
  return .init(lines:lines,scrollWidth:max(Double(frame.width),Double(words.map(\.utf16.count).max() ?? 0)*advance),clientWidth:Double(frame.width),splits:false)
 },outside:{r in let i=r.intersection(interior);return Double(r.width*r.height)-(i.isNull ? 0:Double(i.width*i.height))})
 var v:[String:Any]=["name":f["name"]!,"accepted":result != nil]
 if let r=result {v["font"]=r.font;v["from"]=r.originalFont;v["first"]=r.firstUTF16Length;v["parts"]=r.parts.map {["text":$0.text,"frame":box($0.frame),"ink":box($0.ink)] as [String:Any]};v["panel"]=r.panel.map(box) ?? [];v["coverage"]=r.coverage.map(box)}
 output.append(v)
}
try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
