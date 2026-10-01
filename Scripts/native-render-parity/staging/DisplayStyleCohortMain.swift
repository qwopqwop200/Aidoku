import Foundation
import CoreGraphics

typealias Policy=NativeDisplayStyleCohort
func n(_ d:[String:Any],_ k:String,_ fallback:Double=0)->Double {(d[k] as? NSNumber)?.doubleValue ?? fallback}
func b(_ d:[String:Any],_ k:String,_ fallback:Bool=false)->Bool {d[k] as? Bool ?? fallback}
func rect(_ a:Any?)->CGRect {let a=a as? [Double] ?? [0,0,0,0];return CGRect(x:a[0],y:a[1],width:a[2],height:a[3])}
func member(_ d:[String:Any])->Policy.Member {
 Policy.Member(id:d["id"] as! String,sampled:d["sampled"] as! [Double],fill:d["fill"] as! [Double],stroke:d["stroke"] as? [Double],
 sampledStroke:n(d,"strokeConfidence",1)>=0.55 ? d["sampledStroke"] as? [Double]:nil,sampledBack:d["sampledBack"] as? [Double],
 strokeSource:d["strokeSource"] as? String ?? "",glyph:d["glyph"] as? Double,font:n(d,"font",10),outlined:d["ringKind"] as? String=="outline",
 locked:b(d,"locked"),strokeLocked:d["stroke"] as? [Double] != nil && ["outline","restored-outline","hollow","kept"].contains(d["ringAction"] as? String ?? ""),
 fillLocked:d["ringAction"] as? String=="outline-as-fill",ringKind:d["ringKind"] as? String,ringCore:d["ringCore"] as? [Double],
 ringSurface:d["ringSurface"] as? [Double],ringPlateTo:b(d,"ringPlateTo"),plate:d["plate"] as? [Double],backing:(d["plate"] as? [Double]).map {[Policy.luminance($0),Policy.luminance($0)]} ?? d["backing"] as? [Double],
 ink:rect(d["ink"]),ownerRect:d["ownerRect"]==nil ? nil:rect(d["ownerRect"]),ownerIsNode:b(d,"ownerIsNode"),ownerAlone:b(d,"ownerAlone",true))
}
func run(_ job:[String:Any])->[String:Any] {
 let members=(job["members"] as! [[String:Any]]).map(member)
 return ["name":job["name"] as! String,"decisions":Policy.decisions(members).map {d -> [String:Any] in
  ["id":d.id,"fill":d.fill as Any? ?? NSNull(),"plate":d.plate as Any? ?? NSNull(),"dropStroke":d.dropStroke,"minimumContrast":d.minimumContrast]
 }]
}
@main struct Main {static func main()throws {
 let jobs=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
 try JSONSerialization.data(withJSONObject:jobs.map(run),options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
}}
