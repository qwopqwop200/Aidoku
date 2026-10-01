import Foundation
import QuartzCore
import Metal
import CoreGraphics
import ImageIO
@main struct Probe {
 static func main()throws {
  let directory=URL(fileURLWithPath:CommandLine.arguments[1]),out=URL(fileURLWithPath:CommandLine.arguments[2]),opaque=CommandLine.arguments[3]=="opaque"
  let doc=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("web-dom-and-saved-masks.json"))) as! [String:Any]
  let device=MTLCreateSystemDefaultDevice()!
  for filter in [CALayerContentsFilter.linear,.trilinear,.nearest] {
   let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:960,height:480,mipmapped:false);desc.storageMode = .shared;desc.usage=[.renderTarget,.shaderRead]
   let target=device.makeTexture(descriptor:desc)!
   let root=CALayer();root.frame=CGRect(x:0,y:0,width:960,height:480);root.isGeometryFlipped=true
   if opaque{root.backgroundColor=CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[41.0/255,65.0/255,87.0/255,1])}
   CATransaction.begin();CATransaction.setDisableActions(true)
   for record in doc["records"] as! [[String:Any]] {
    let id=record["id"] as! String,b=record["used"] as! [Double]
    let src=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(directory.appendingPathComponent("source-canvas-\(id).png") as CFURL,nil)!,0,nil)!
    let layer=CALayer();layer.frame=CGRect(x:b[0]*3,y:b[1]*3,width:b[2]*3,height:b[3]*3);layer.contents=src;layer.contentsGravity = .resize;layer.minificationFilter=filter;layer.magnificationFilter = .linear;root.addSublayer(layer)
   }
   CATransaction.commit();CATransaction.flush()
   let renderer=CARenderer(mtlTexture:target,options:[kCARendererColorSpace:CGColorSpace(name:CGColorSpace.sRGB)!]);renderer.layer=root;renderer.bounds=root.bounds
   renderer.beginFrame(atTime:CACurrentMediaTime(),timeStamp:nil);renderer.addUpdate(root.bounds);renderer.render();renderer.endFrame()
   var bgra=Data(count:960*480*4);bgra.withUnsafeMutableBytes{target.getBytes($0.baseAddress!,bytesPerRow:3840,from:MTLRegionMake2D(0,0,960,480),mipmapLevel:0)}
   var data=Data(count:bgra.count)
   for i in stride(from:0,to:data.count,by:4){data[i]=bgra[i+2];data[i+1]=bgra[i+1];data[i+2]=bgra[i];data[i+3]=bgra[i+3]}
   try data.write(to:out.appendingPathComponent("CA-\(filter.rawValue).rgba"))
   let ref=try Data(contentsOf:directory.appendingPathComponent("web-live-320.rgba"));var n=0,maxd=0
   for i in stride(from:0,to:data.count,by:4){var d=0;for j in 0..<4{d=max(d,abs(Int(data[i+j])-Int(ref[i+j])))};n+=d>0 ? 1:0;maxd=max(maxd,d)}
   print(filter.rawValue,n,maxd,Array(data.prefix(4)))
  }
 }
}
