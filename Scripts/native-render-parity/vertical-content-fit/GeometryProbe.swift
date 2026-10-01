import Foundation
import CoreGraphics
@main struct GeometryProbe {
 static func main() throws {
  let rows=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
  var output:[[Int]]=[]
  for row in rows {
   let a=row["a"] as! [String:Any],box=row["box"] as! [Double],padding=row["padding"] as! [Double],item=row["itemBox"] as! [Double],lines=row["lines"] as! [[Double]]
   let columns=Set(lines.map {($0[0]*100000).rounded()}).count
   let metrics=NativeVerticalContentFit.metrics(box:CGSize(width:box[2],height:box[3]),padding:.init(top:padding[0],right:padding[1],bottom:padding[2],left:padding[3]),columnCount:columns,fontSize:a["font"] as! Double,lineHeight:a["pitch"] as! Double,inlineExtent:item[3],alignsToRight:a["balanced"] as! Bool,clips:a["clips"] as! Bool)!
   output.append([metrics.clientWidth,metrics.clientHeight,metrics.scrollWidth,metrics.scrollHeight])
  }
  try JSONSerialization.data(withJSONObject:output).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
