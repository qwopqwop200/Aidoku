import CoreGraphics
import Foundation
@main struct OwnershipProbe {
 static func main() throws {
 let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
 func rect(_ a:[NSNumber])->CGRect { .init(x:a[0].doubleValue,y:a[1].doubleValue,width:a[2].doubleValue,height:a[3].doubleValue) }
 var results:[[String:Any]]=[]
 for f in fixtures {
 let panels=(f["panels"] as! [[String:Any]]).map { p in NativeEarlyBalloonOwnership.Panel(id:p["id"] as! String,rect:rect(p["rect"] as! [NSNumber]),opaque:p["opaque"] as! Bool,clipped:p["clipped"] as! Bool,visible:p["visible"] as! Bool,opacity:(p["opacity"] as! NSNumber).doubleValue,sourceErasure:p["erasure"] as! Bool,explicitCoverage:(p["coverage"] as? [[NSNumber]])?.map(rect)) }
 let captions=(f["captions"] as! [[String:Any]]).map { c in
 let size=c["size"] as! [NSNumber]
 return NativeEarlyBalloonOwnership.Caption(id:c["id"] as! String,sources:(c["sources"] as! [[NSNumber]]).map(rect),ink:rect(c["ink"] as! [NSNumber]),inpainted:c["inpainted"] as! Bool,verified:c["verified"] as! Bool,provisional:c["provisional"] as! Bool,partial:c["partial"] as! Bool,erasureComplete:c["complete"] as! Bool,canvasConnected:c["connected"] as! Bool,canvasSize:.init(width:size[0].doubleValue,height:size[1].doubleValue)) }
 let result=NativeEarlyBalloonOwnership.permits(ownerIndex:0,panels:panels,captions:captions,legible:f["legible"] as! Bool)
 results.append(["id":f["id"]!,"accepted":result.accepted])
 }
 try JSONSerialization.data(withJSONObject:results).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
