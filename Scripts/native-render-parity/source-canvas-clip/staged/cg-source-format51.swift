import Foundation
import CoreGraphics
import ImageIO
@main struct Probe {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),out=URL(fileURLWithPath:CommandLine.arguments[2])
  let rgba=try Data(contentsOf:root.appendingPathComponent("immutable-actual44-mask0.rgba"))
  let png=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(root.appendingPathComponent("immutable-actual44-mask0.png") as CFURL,nil)!,0,nil)!
  var sources:[(String,CGImage)]=[("png",png)]
  for bgra in [false,true] {for bitmap in [false,true] {
   var bytes=rgba
   if bgra { for i in stride(from:0,to:bytes.count,by:4){let v=bytes[i];bytes[i]=bytes[i+2];bytes[i+2]=v} }
   let info=bgra ? CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue : CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue
   let image:CGImage
   if bitmap {
    image=bytes.withUnsafeMutableBytes { p in CGContext(data:p.baseAddress!,width:412,height:527,bitsPerComponent:8,bytesPerRow:1648,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:info)!.makeImage()! }
   } else {image=CGImage(width:412,height:527,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:1648,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:info),provider:CGDataProvider(data:bytes as CFData)!,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!}
   sources.append(("\(bgra ? "bgra":"rgba")-\(bitmap ? "bitmap":"provider")",image))
  } }
  var metadata:[[String:Any]]=[]
  for (name,image) in sources {
   let ctx=CGContext(data:nil,width:273,height:363,bitsPerComponent:8,bytesPerRow:1092,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue)!
   ctx.setShouldAntialias(false);ctx.draw(image,in:CGRect(x:0,y:0,width:273,height:363))
   try Data(bytes:ctx.data!,count:273*363*4).write(to:out.appendingPathComponent(name+".rgba"))
   metadata.append(["source":name,"bitmapInfo":image.bitmapInfo.rawValue,"alphaInfo":image.alphaInfo.rawValue,"space":image.colorSpace?.name as String? ?? "nil","interpolationQuality":ctx.interpolationQuality.rawValue])
  }
  try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("metadata.json"))
 }
}
