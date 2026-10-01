import Foundation
import CoreGraphics
@main enum Probe {
 static func main() throws {
  let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
  func rect(_ r:[Double])->CGRect { CGRect(x:r[0],y:r[1],width:r[2],height:r[3]) }
  let output: [Any] = fixtures.map { f in
   let inputs = f["records"] as! [[String:Any]]
   let records = inputs.map { r -> NativePanelGeometry.Record in
    let panels = (r["panels"] as! [[String:Any]]).map { p -> NativeTranslationSourceStylePostPolish.Panel in
     var q = NativeTranslationSourceStylePostPolish.Panel(rect:rect(p["rect"] as! [Double]),background:p["color"] as! [Double],coverage:(p["coverage"] as! [[Double]]).map(rect));q.sourceErasure=p["sourceErasure"] as! Bool;return q
    }
    var q = NativePanelGeometry.Record(id:r["id"] as! String,ink:rect(r["ink"] as! [Double]),source:nil,sources:[],sourceColorEligible:r["eligible"] as! Bool,sourceTextOnly:r["textOnly"] as! Bool,balancedColumn:false,vertical:false,rotation:0,font:r["font"] as! Double,sourceFont:nil,sourceVertical:false,inkPadding:3,foreground:r["inkRGB"] as! [Double],fallbackBackground:r["fallback"] as! [Double],panels:panels)
    q.backings=(r["backings"] as! [[String:Any]]).map { b in .init(frame:rect(b["frame"] as! [Double]),coverage:(b["coverage"] as! [[Double]]).map(rect),color:b["color"] as! [Double]) };return q
   }
   let result=NativeEarlyPlateContrast.apply(records,opacity:f["opacity"] as! Double,itemCount:f["itemCount"] as! Int)
   return result.records.enumerated().map { i,r -> [String:Any] in
    let extra=r.backings.dropFirst(records[i].backings.count).last?.coverage.first
    let decision=result.decisions.first { $0.id==r.id }
    let metadata:Any=decision.map { ["before":$0.before,"after":$0.after,"surfaces":$0.surfaces,"minimumBefore":$0.minimumBefore,"minimumAfter":$0.minimumAfter] as [String:Any] } as Any? ?? NSNull()
    return ["id":r.id,"foreground":r.foreground,"backing":extra.map { [Double($0.minX),Double($0.minY),Double($0.width),Double($0.height)] } as Any? ?? NSNull(),"decision":metadata]
   }
  }
  try JSONSerialization.data(withJSONObject:output).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
