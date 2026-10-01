import Foundation
import CoreGraphics
@main struct MarginProbe {
 static func main() throws {
  let jobs = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
  var outputs: [Any] = []
  for f in jobs {
   func a(_ k:String)->[Double] { (f[k] as! [NSNumber]).map(\.doubleValue) }
   func r(_ v:[Double])->CGRect { CGRect(x:v[0],y:v[1],width:v[2],height:v[3]) }
   let size=a("imageSize"),crop=a("crop"),scale=a("scale"),padding=a("padding")
   let g=NativeFinalRestorationTrial.Geometry(imageSize:CGSize(width:size[0],height:size[1]),frame:r(a("frame")),cropOrigin:CGPoint(x:crop[0],y:crop[1]),scale:CGSize(width:scale[0],height:scale[1]),sourceBounds:a("sourceBounds"),auxiliaryInkRects:(f["aux"] as! [[NSNumber]]).map{$0.map(\.doubleValue)},sourceFontSize:(f["font"] as! NSNumber).doubleValue)
   guard let c=NativeFinalRestorationTrial.marginCoverage(geometry:g,sourceFrame:r(a("sourceFrame")),oldPlate:r(a("plate")),padding:CGSize(width:padding[0],height:padding[1]),displayedFontSize:(f["displayFont"] as! NSNumber).doubleValue) else {outputs.append(["accepted":false,"geometry":NSNull()]);continue}
   let s=NativeResidualTopology.Surface(width:f["w"] as! Int,height:f["h"] as! Int,rgba:[],safe:(f["safe"] as! [Int]).map(UInt8.init),luminance:[])
   let accepted=NativeFinalRestorationTrial.certifiesEarlyMargin(surface:s,coverage:c,sourceVertical:f["vertical"] as! Bool,sourceSingleColumn:f["single"] as! Bool,restorationMethod:f["method"] as? String,sourceGlyphsVerified:f["glyphsVerified"] as! Bool,sourceErasureVerified:f["verified"] as! Bool,groupRecheck:f["group"] as! Bool)
   outputs.append(["accepted":accepted,"geometry":["viewportRects":c.viewportRects.map{[Double($0.origin.x),Double($0.origin.y),Double($0.width),Double($0.height)]},"regions":c.regions,"core":c.core,"glyphSize":c.glyphSize]])
  }
  try JSONSerialization.data(withJSONObject:outputs,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
