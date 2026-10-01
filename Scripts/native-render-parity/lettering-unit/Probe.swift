import Foundation
import CoreGraphics
@main struct UnitProbe {
 static func main() throws {
  let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String:Any]]
  func rect(_ r:[Double])->CGRect { CGRect(x:r[0],y:r[1],width:r[2],height:r[3]) }
  func array(_ r:CGRect)->[Double] { [Double(r.origin.x),Double(r.origin.y),Double(r.size.width),Double(r.size.height)] }
  var output:[[String:Any]]=[]
  for row in rows {
   let raw=row["members"] as! [[String:Any]]
   let members=raw.compactMap { m -> NativeLetteringUnitPalette.Member? in
    guard m["visible"] as? Bool != false, m["glyphCover"] as? Bool != true,
     m["children"] as? Int ?? 1 <= 1, !(m["text"] as! String).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
     ["readability-panel","rotated-panel"].contains(m["mode"] as! String) else { return nil }
    let ring=m["ring"] as? [String:Any]
    let source=m["source"] as? [Double] ?? ((ring?["kind"] as? String).map { ["outline","paper"].contains($0) } == true ? ring?["core"] as? [Double] : nil)
    guard let source else { return nil }
    return .init(id:m["id"] as! String,box:rect(m["box"] as! [Double]),plate:m["plate"] as! [Double],fill:m["fill"] as! [Double],source:source,
     surface:ring?["surface"] as? [Double],glyph:m["glyph"] as! Double,font:m["font"] as! Double,stroke:m["stroke"] as? [Double],strokeWidth:m["strokeWidth"] as! Double,vertical:m["vertical"] as! Bool)
   }
   let neighbors=(raw+(row["neighbors"] as! [[String:Any]])).filter { $0["visible"] as? Bool != false }.map { m in
    NativeLetteringUnitPalette.Neighbor(id:m["id"] as! String,ink:rect(m["ink"] as! [Double]),fill:m["fill"] as? [Double])
   }
   let panels=raw.map { m in NativeLetteringUnitPalette.Panel(id:m["id"] as! String,color:m["plate"] as! [Double],fills:(m["fills"] as! [[String:Any]]).map { .init(rect:rect($0["rect"] as! [Double]),color:$0["color"] as! [Double]) }) }
   let result=NativeLetteringUnitPalette.resolve(members:members,neighbors:neighbors,panels:panels,itemCount:row["itemCount"] as! Int,
    opacity:row["opacity"] as! Double,preserveText:row["preserveText"] as! Bool,preserveBackground:row["preserveBackground"] as! Bool)
   let updates=result.updates.map { u -> [String:Any] in
    var record:[String:Any]=["plate":[u.oldPlate,u.plate]];if u.oldFill != u.fill { record["fill"]=[u.oldFill,u.fill] }
    return ["id":u.id,"record":record,"fill":u.fill,"stroke":u.stroke.map { $0 as Any } ?? NSNull(),"width":u.strokeWidth,"contrast":u.minimumContrast]
   }
   output.append(["updates":updates,"panels":result.panels.map { p in ["id":p.id,"color":p.color,"fills":p.fills.map { ["rect":array($0.rect),"color":$0.color] }] }])
  }
  try JSONSerialization.data(withJSONObject:output,options:.sortedKeys).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
