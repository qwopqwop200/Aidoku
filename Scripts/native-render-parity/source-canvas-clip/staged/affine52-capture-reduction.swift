import Foundation
import CoreGraphics
@main struct Reduction {
 static func main()throws {
  let input=URL(fileURLWithPath:CommandLine.arguments[1]),reference=URL(fileURLWithPath:CommandLine.arguments[2]);var reports:[[String:Any]]=[]
  for scene in ["identity","nonuniform","fractional-origin","rotation"] {
   let bytes=try Data(contentsOf:input.appendingPathComponent(scene+".rgba"))
   let image=CGImage(width:960,height:480,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:3840,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:bytes as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
   let reduced=try NativeCanvasTextureResampler.resample(image:image,outputPixelSize:CGSize(width:480,height:240))
   let small=reduced.dataProvider!.data! as Data;try small.write(to:input.appendingPathComponent(scene+"-160.rgba"))
   for requested in [320,160] {
    let native=requested==320 ? bytes:small,web=try Data(contentsOf:reference.appendingPathComponent(scene).appendingPathComponent("web-live-\(requested).rgba"));var changed=0,delta=0
    guard native.count==web.count else{throw NSError(domain:"capture dimensions differ",code:1)}
    for i in stride(from:0,to:native.count,by:4){var d=0;for c in 0..<4{d=max(d,abs(Int(native[i+c])-Int(web[i+c])))};changed += d>0 ? 1:0;delta=max(delta,d)}
    reports.append(["scene":scene,"requestedWidth":requested,"changedPixels":changed,"maxChannelDelta":delta,"exactRGBA":changed==0]);print(scene,requested,changed,delta)
   }
  }
  try JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys]).write(to:input.appendingPathComponent("all-eight-results.json"))
 }
}
