import CoreGraphics
import Foundation
@main struct Main {
 static func rect(_ a: [Double]) -> CGRect { CGRect(x:a[0],y:a[1],width:a[2],height:a[3]) }
 static func array(_ r: CGRect) -> [Double] { [r.origin.x,r.origin.y,r.size.width,r.size.height] }
 static func main() throws {
  let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [[String:Any]]
  let output: [[String:Any]] = input.map { f in
   let r=rect(f["rect"] as! [Double]), n=f["natural"] as! [Double]
   let g=NativeSourceSurfaceGeometry.contentGeometry(rect:r,naturalSize:CGSize(width:n[0],height:n[1]),style:f["style"] as! [String:String])
   let clip=NativeSourceSurfaceGeometry.cleanupClip(g,rect:rect(f["probe"] as! [Double]))
   let origin=f["origin"] as! [Double]
   let rebased=NativeSourceSurfaceGeometry.rebaseCoverageClip((f["coverage"] as! [[Double]]).map(rect),origin:CGPoint(x:origin[0],y:origin[1]),hasClip:f["hasClip"] as! Bool)
   return ["geometry":g.map { ["frame":array($0.frame),"clip":array($0.clip)] } as Any? ?? NSNull(),
           "insets":clip.empty ? [50.0,50,50,50] : [Double(clip.top),Double(clip.right),Double(clip.bottom),Double(clip.left)],
           "empty":clip.empty,"coverage":rebased.map { $0.map(array) } as Any? ?? NSNull()]
  }
  FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]))
 }
}
