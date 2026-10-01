import Foundation
import CoreGraphics
func rect(_ v:[Double])->CGRect {CGRect(x:v[0],y:v[1],width:v[2],height:v[3])}
func a(_ r:CGRect)->[Double] {[Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)]}
func shape(_ text:String,_ font:Double,_ width:Double,_ pitch:Double,_ padding:Double)->NativeTranslationDisplayGroups.Measurement {
 let advance=font*0.55,room=width-padding*2,limit=max(1,Int(floor(room/advance)))
 var rows=[0]
 for word in text.split(separator:" ") {
  var index=rows.count-1
  if rows[index]>0 && rows[index]+1+word.utf16.count>limit {rows.append(0);index+=1}else if rows[index]>0 {rows[index]+=1}
  rows[index]+=word.utf16.count
 }
 let lines=rows.enumerated().map {i,n in CGRect(x:(width-Double(n)*advance)/2,y:Double(i)*pitch+(pitch-font)/2,width:Double(n)*advance,height:font)}
 return .init(size:CGSize(width:width,height:Double(rows.count)*pitch),lines:lines,scrollWidth:max(width,Double(rows.max()!)*advance+padding*2),clientWidth:width)
}
let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
let out=fixtures.map {f -> [String:Any] in
 let cells=(f["cells"] as! [[String:Any]]).map {d -> NativeTranslationDisplayGroups.Cell in
  let c=d["center"] as! [Double]
  return .init(id:d["id"] as! String,text:d["text"] as! String,glyph:d["glyph"] as! Double,font:d["font"] as! Double,color:d["color"] as! [Double],width:d["width"] as! Double,height:d["height"] as! Double,angle:d["angle"] as! Double,center:CGPoint(x:c[0],y:c[1]))
 }
 let foreign=Dictionary((f["foreign"] as? [[String:Any]] ?? []).map {($0["id"] as! String,rect($0["rect"] as! [Double]))},uniquingKeysWith:{$1})
 let result=NativeTranslationDisplayGroups.arrange(cells,foreign:foreign,measure:{cell,font,width,pitch,padding in shape(cell.text,font,width,pitch,padding)})
 return ["name":f["name"]!,"groups":result.groups,"states":result.placements.map {p in ["id":p.id,"members":p.members,"order":p.order,"from":p.originalFont,"font":p.font,"pitch":p.pitch,"padding":p.padding,"rect":a(p.rect),"angle":p.angle,"lines":p.lines.map(a)]}]
}
try JSONSerialization.data(withJSONObject:out,options:.sortedKeys).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
