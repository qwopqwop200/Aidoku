import AppKit
import QuartzCore
import CryptoKit
@main struct Smoke {
 @MainActor static func main() async throws {
  let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
  try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
  var reports:[[String:Any]]=[]
  for flush in [false,true] {
   for (name,rgb) in [("red",[220.0,30,40]),("blue",[30.0,40,220])] {
    let root=CALayer();root.frame=CGRect(x:0,y:0,width:320,height:160);root.contentsScale=3
    func color(_ c:[Double])->CGColor {CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:c.map{CGFloat(Float($0/255))}+[1])!}
    root.backgroundColor=color([41,65,87])
    let gradient=CAGradientLayer();gradient.frame=CGRect(x:20,y:20,width:96,height:96);gradient.contentsScale=3
    gradient.type = .axial;gradient.startPoint=CGPoint(x:0.5,y:0);gradient.endPoint=CGPoint(x:0.5,y:1);gradient.locations=[0,1]
    gradient.colors=[color(rgb),color(rgb)];root.addSublayer(gradient)
    let bytes:Data;let metadata:[String:Any]
    if flush {let c=try await NativeDetachedLayerMetalCaptureFlush.capture(root:root,size:CGSize(width:320,height:160),scale:3);bytes=c.canonicalRGBA;metadata=c.metadata}
    else {let c=try await NativeDetachedLayerMetalCaptureNoFlush.capture(root:root,size:CGSize(width:320,height:160),scale:3);bytes=c.canonicalRGBA;metadata=c.metadata}
    let label=name+(flush ? "-flush":"-no-flush")
    try bytes.write(to:output.appendingPathComponent(label+".rgba"))
    var alpha:[String:Int]=[:]
    for i in stride(from:3,to:bytes.count,by:4){alpha[String(bytes[i]),default:0]+=1}
    reports.append(["mode":label,"RGBAHash":SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined(),"alphaHistogram":alpha,"renderer":metadata])
    gradient.removeFromSuperlayer()
   }
  }
  try JSONSerialization.data(withJSONObject:["scope":"windowless macOS actual public CARenderer lifecycle A/B; no iOS parity claim","reports":reports],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
 }
}
