import Foundation
import CoreGraphics
func rect(_ a:[Double])->CGRect {CGRect(x:a[0],y:a[1],width:a[2],height:a[3])}
func quad(_ a:[[Double]])->[CGPoint] {a.map{CGPoint(x:$0[0],y:$0[1])}}
let rows=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
var out:[[String:Any]]=[]
for row in rows {
 let layers=(row["layers"] as! [[String:Any]]).map { a in NativeTranslationPaintOrder.Layer(id:a["id"] as! String,z:a["z"] as! Int,order:a["order"] as! Double,quad:quad(a["quad"] as! [[Double]]),coverage:(a["coverage"] as! [[Double]]).map(rect),usesQuad:a["usesQuad"] as! Bool,opaque:a["opaque"] as! Bool,shown:a["shown"] as! Bool,background:a["background"] as? [Double]) }
 let nodes=(row["nodes"] as! [[String:Any]]).map { a in NativeTranslationPaintOrder.Node(id:a["id"] as! String,layerID:a["layerID"] as! String,glyphs:(a["glyphs"] as! [[Double]]).map(rect),quad:quad(a["quad"] as! [[Double]]),isRoot:a["isRoot"] as! Bool,opaque:a["opaque"] as! Bool,rotatingPanel:a["rotatingPanel"] as! Bool,ownRotatedPlate:a["ownRotatedPlate"] as? String,foreground:a["foreground"] as? [Double]) }
 let r=NativeTranslationPaintOrder.apply(nodes:nodes,layers:layers,itemCount:row["count"] as! Int)
 out.append(["nodes":r.nodes.map{["id":$0.id,"lift":$0.lift as Any? ?? NSNull()]},"layers":r.layers.map{["id":$0.id,"z":$0.z]},"order":r.layers.sorted{$0.order<$1.order}.map(\.id),"lifted":r.lifted])
}
print(String(data:try JSONSerialization.data(withJSONObject:out,options:[.sortedKeys]),encoding:.utf8)!)
