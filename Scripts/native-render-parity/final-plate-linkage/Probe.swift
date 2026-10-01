import Foundation
import CoreGraphics
@main struct PlateProbe {
 static func main() throws {
  let jobs=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
  func rect(_ r:[Double])->CGRect { CGRect(x:r[0],y:r[1],width:r[2],height:r[3]) }
  func array(_ r:CGRect)->[Double] { [r.origin.x,r.origin.y,r.size.width,r.size.height] }
  var output:[[String:Any]]=[]
  for j in jobs {
   let frame=rect(j["frame"] as! [Double])
   func page(_ r:[Double])->CGRect { CGRect(x:frame.minX+r[0]*frame.width,y:frame.minY+r[1]*frame.height,width:r[2]*frame.width,height:r[3]*frame.height) }
   func flag(_ d:[String:Any],_ name:String,_ defaultValue:Bool=false)->Bool { d[name] as? Bool ?? defaultValue }
   let items=(j["items"] as! [[String:Any]]).map { i in
    let source=i["source"] as? [Double]
    return NativeFinalPlateLinkage.Item(id:i["id"] as! String,rotation:(i["rotation"] as? Double) ?? 0,vertical:flag(i,"vertical"),sourceVertical:flag(i,"sourceVertical"),sourceFont:i["sourceFont"] as? Double,sourceBounds:source,auxiliaryBounds:i["aux"] as? [[Double]] ?? [])
   }
   let nodes=(j["nodes"] as! [[String:Any]]).map { n in NativeFinalPlateLinkage.Node(id:n["id"] as! String,ink:rect(n["ink"] as! [Double]),font:n["font"] as! Double,shown:flag(n,"shown",true),transformed:flag(n,"transformed"),fits:flag(n,"fits",true),sampledColors:n["colors"] as? [[Double]] ?? []) }
   let panels=(j["panels"] as! [[String:Any]]).map { p in NativeFinalPlateLinkage.Panel(id:p["id"] as! String,box:rect(p["box"] as! [Double]),coverage:(p["coverage"] as? [[Double]]).map { $0.map(rect) },color:p["color"] as! [Double],rootChild:flag(p,"rootChild",true),sourceErasure:flag(p,"sourceErasure"),preservedCaption:flag(p,"preservedCaption"),foreignFills:flag(p,"foreignFills"),transformed:flag(p,"transformed"),backing:flag(p,"backing"),shown:flag(p,"shown",true),unknownClip:flag(p,"unknownClip"),restoration:(p["restoration"] as? [Double]).map(rect)) }
   var crops:[[Int]]=[]
   let art=j["art"] as! [[Double]],bg=j["background"] as! [Double]
   let result=NativeFinalPlateLinkage.resolve(items:items,nodes:nodes,panels:panels,frame:frame,imageSize:CGSize(width:j["iw"] as! Int,height:j["ih"] as! Int),opacity:j["opacity"] as! Double,preserveBackground:j["preserveBackground"] as! Bool) { crop in
    crops.append([crop.x,crop.y,crop.width,crop.height]);var bytes=[UInt8](repeating:0,count:crop.width*crop.height*4)
    for y in 0..<crop.height { for x in 0..<crop.width {
     let sx=Double(crop.x+x),sy=Double(crop.y+y),r=art.last { sx >= $0[0] && sy >= $0[1] && sx < $0[0]+$0[2] && sy < $0[1]+$0[3] },color=r.map { Array($0.suffix(4)) } ?? bg
     for c in 0..<4 { bytes[(y*crop.width+x)*4+c]=UInt8(color[c]) }
    } };return bytes
   }
   output.append(["links":result.links.map { l in ["index":l.panelIndex,"id":l.id,"box":array(result.panels[l.panelIndex].box),"coverage":result.panels[l.panelIndex].coverage.map { $0.map(array) } as Any? ?? NSNull(),"release":[Double(l.releases.count),floor(l.releasedArea+0.5)],"move":l.move.map { [floor($0.x*10+0.5)/10,floor($0.y*10+0.5)/10] } as Any? ?? NSNull()] },"remaining":result.remainingPixels,"crops":crops])
  }
  try JSONSerialization.data(withJSONObject:output,options:.sortedKeys).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
