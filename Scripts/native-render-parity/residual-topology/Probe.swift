import Foundation
import CoreGraphics
@main struct Probe {
 static func main() throws {
  let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
  var outputs: [Any] = []
  for f in rows {
   let w = f["w"] as! Int, h = f["h"] as! Int, op = f["op"] as! String
   func bytes(_ key: String) -> [UInt8] { (f[key] as! [Int]).map(UInt8.init) }
   func array(_ key: String) -> [Double] { (f[key] as! [NSNumber]).map(\.doubleValue) }
   func rects(_ key: String) -> [[Double]] { (f[key] as! [[NSNumber]]).map { $0.map(\.doubleValue) } }
   func number(_ key: String) -> Double { (f[key] as! NSNumber).doubleValue }
   func frame(_ key: String) -> CGRect { let a = array(key); return CGRect(x:a[0],y:a[1],width:a[2],height:a[3]) }
   if op == "specks" {
    var s = NativeResidualTopology.Surface(width:w,height:h,rgba:bytes("rgba"),safe:bytes("safe"),luminance:bytes("luminance"),surfaceRevision:f["revision"] as! Int,coreClear:f["coreClear"] as? Bool,innerCoreClear:f["innerCoreClear"] as? Bool,residualLettering:f["residualLettering"] as? Bool)
    func snapshot(_ s: NativeResidualTopology.Surface) -> [String:Any] { ["rgba":s.rgba,"safe":s.safe,"luminance":s.luminance,"revision":s.surfaceRevision,"enclosedSpecks":s.enclosedSpecks as Any? ?? NSNull(),"coreClear":s.coreClear as Any? ?? NSNull(),"innerCoreClear":s.innerCoreClear as Any? ?? NSNull(),"residualLettering":s.residualLettering as Any? ?? NSNull()] }
    let undo = NativeResidualTopology.fillEnclosedSpecks(surface:&s), filled = snapshot(s)
    undo?.restore(&s)
    outputs.append(["accepted":undo != nil,"filled":filled,"undone":snapshot(s),"puts":undo == nil ? 0 : 2])
   } else if op == "foreign" {
    let image = array("imageSize"), crop = array("crop"), scale = array("scale")
    outputs.append(NativeResidualTopology.hiddenForeignRepaint(width:w,height:h,imageSize:CGSize(width:image[0],height:image[1]),frame:frame("frame"),cropOrigin:CGPoint(x:crop[0],y:crop[1]),scale:CGSize(width:scale[0],height:scale[1]),sourceFontSize:number("sourceFontSize"),sourceBounds:array("sourceBounds"),auxiliaryInkRects:rects("auxiliaryInkRects"),plate:frame("plate"),detachedProposal:f["detached"] as! Bool,rgba:bytes("rgba")))
   } else {
    let safe = bytes("safe"), glyph = number("glyph"), regions = rects("regions"), core = rects("core")
    switch op {
     case "residual": outputs.append(NativeResidualTopology.hasResidualLettering(safe:safe,width:w,height:h,regions:regions,glyphSize:glyph))
     case "attached": outputs.append(NativeResidualTopology.hasAttachedLeadingInk(safe:safe,width:w,height:h,core:core,glyph:glyph))
     case "covers": outputs.append(NativeResidualTopology.restoredErasureCovers(safe:safe,width:w,height:h,regions:regions,glyphSize:glyph,core:core))
     default: outputs.append(NativeResidualTopology.mainbodyCellsClear(safe:safe,width:w,height:h,regions:regions))
    }
   }
  }
  try JSONSerialization.data(withJSONObject:outputs,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
