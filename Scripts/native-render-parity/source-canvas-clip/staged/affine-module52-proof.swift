import Foundation
import CoreGraphics
@main struct AffineModuleProof {
 static func image(_ bytes:Data,_ w:Int,_ h:Int)->CGImage {
  CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:bytes as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
 }
 static func metrics(_ a:Data,_ b:Data)->[String:Int] {precondition(a.count==b.count);var count=0,delta=0;for i in stride(from:0,to:a.count,by:4){var d=0;for c in 0..<4{d=max(d,abs(Int(a[i+c])-Int(b[i+c])))};count += d>0 ? 1:0;delta=max(delta,d)};return ["changedPixels":count,"maxChannelDelta":delta]}
 static func crop(_ bytes:Data,_ box:CGRect,width:Int)->Data {var b=Data();for row in Int(box.minY)..<Int(box.maxY){b.append(bytes[((row*width+Int(box.minX))*4)..<((row*width+Int(box.maxX))*4)])};return b}
 static func main()throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),out=URL(fileURLWithPath:CommandLine.arguments[2]);var reports:[[String:Any]]=[]
  for scene in ["identity","nonuniform","fractional-origin","rotation"] {
   let dir=root.appendingPathComponent(scene),doc=try JSONSerialization.jsonObject(with:Data(contentsOf:dir.appendingPathComponent("web-dom-and-saved-masks.json"))) as! [String:Any],m=doc["matrix"] as! [Double]
   let t=CGAffineTransform(a:m[0]*3,b:m[1]*3,c:m[2]*3,d:m[3]*3,tx:m[4]*3,ty:m[5]*3)
   let size=CGSize(width:960,height:480),whole=CGRect(origin:.zero,size:size),window=CGRect(x:63,y:27,width:571,height:317)
   var full=Data(repeating:0,count:960*480*4);for i in stride(from:0,to:full.count,by:4){full[i]=41;full[i+1]=65;full[i+2]=87;full[i+3]=255};var part=crop(full,window,width:960)
   let session=NativeCanvasTextureResampler.Session();defer{session.close()}
   for record in doc["records"] as! [[String:Any]] {
    let id=record["id"] as! String,w=record["width"] as! Int,h=record["height"] as! Int,f=record["used"] as! [Double],bytes=try Data(contentsOf:dir.appendingPathComponent("source-native-\(id).rgba")),source=image(bytes,w,h),rect=CGRect(x:f[0],y:f[1],width:f[2],height:f[3])
    let opaque = try NativeCanvasTextureResampler.isOpaqueSource(image:source, session:session)
    precondition(opaque, "Opaque control canonical source unexpectedly translucent")
    let result=try NativeCanvasTextureResampler.affineCanvasImage(image:source,domRect:rect,userToPixelTransform:t,viewportPixelSize:size,cropPixels:whole,backgroundRGBA:full,session:session)
    full=result.dataProvider!.data! as Data
    let small=try NativeCanvasTextureResampler.affineCanvasImage(image:source,domRect:rect,userToPixelTransform:t,viewportPixelSize:size,cropPixels:window,backgroundRGBA:part,session:session)
    part=small.dataProvider!.data! as Data
    let raw=try NativeCanvasTextureResampler.affineCanvasImage(image:source,domRect:rect,userToPixelTransform:t,viewportPixelSize:size,cropPixels:window,session:session).dataProvider!.data! as Data
    for index in stride(from:0,to:raw.count,by:4) {let alpha=raw[index+3];precondition(raw[index]<=alpha);precondition(raw[index+1]<=alpha);precondition(raw[index+2]<=alpha)}
   }
   let cropDifference=metrics(part,crop(full,window,width:960));print(scene,"crop",cropDifference)
   precondition(cropDifference["changedPixels"]==0,"Tile/crop changes full-viewport sampling")
   try full.write(to:out.appendingPathComponent(scene+".rgba"))
   let reduced=try NativeCanvasTextureResampler.resample(image:image(full,960,480),outputPixelSize:CGSize(width:480,height:240)).dataProvider!.data! as Data
   try reduced.write(to:out.appendingPathComponent(scene+"-160.rgba"))
   for requested in [320,160] {let native=requested==320 ? full:reduced,web=try Data(contentsOf:dir.appendingPathComponent("web-live-\(requested).rgba")),difference=metrics(native,web);reports.append(["scene":scene,"requestedWidth":requested,"metrics":difference,"cropAgreement":cropDifference]);print(scene,requested,difference)}
  }
  try JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("all-eight-results.json"))
 }
}
