import Foundation
import CoreGraphics
@main struct Probe {
 static func main() throws {
  let cases=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
  let results=cases.map { c -> [String:Any] in
   let raw=c["raw"] as! [Double],used=c["used"] as! [Double],parent=c["parent"] as! [Double]
   let authored=CGRect(x:raw[0]+parent[0],y:raw[1]+parent[1],width:raw[2],height:raw[3])
   let dom=CGRect(x:used[0]+parent[0],y:used[1]+parent[1],width:used[2],height:used[3])
   let clip=(c["clip"] as? [Double]).map {CGRect(x:$0[0]+parent[0],y:$0[1]+parent[1],width:$0[2],height:$0[3])}
   let live=NativeSourceCanvasClip.liveClip(authoredRect:authored,domRect:dom,cleanupClip:clip,deviceScale:c["deviceScale"] as! Double)
   let ref=NativeSourceCanvasClip.referenceRect(domRect:dom,deviceScale:c["deviceScale"] as! Double)
   return ["id":c["id"]!,"live":live.map {[Double($0.origin.x),Double($0.origin.y),Double($0.size.width),Double($0.size.height)]} as Any? ?? NSNull(),"reference":[Double(ref.origin.x),Double(ref.origin.y),Double(ref.size.width),Double(ref.size.height)]]
  }
  try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
