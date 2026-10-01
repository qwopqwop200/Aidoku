import Foundation
import CoreText
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@main struct Probe {
 static func main() throws {
  let row = (try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]])[0]
  let a=row["a"] as! [String:Any],f=a["font"] as! Double,p=a["pitch"] as! Double,pads=a["pads"] as! [Double]
  func unit(_ v:Double)->CGFloat{CGFloat((Float(v)*64).rounded(.towardZero))/64}
  let style=NativeTranslationTypography.Style(fontScript:a["script"] as! String,fontSize:f,vertical:true,
   tracking:(a["tracking"] as? Double).map{CGFloat($0)},lineHeight:p,alignsToTop:a["balanced"] as! Bool,strictLineBreak:true)
  let size=CGSize(width:unit(a["width"] as! Double)-unit(pads[1])-unit(pads[3]),height:unit(a["height"] as! Double)-unit(pads[0])-unit(pads[2]))
  let layout=NativeTranslationTypography.layout(text:a["text"] as! String,in:size,style:style)
  let data=NSMutableData(),consumer=CGDataConsumer(data:data as CFMutableData)!
  var media=CGRect(x:0,y:0,width:390,height:700)
  let ctx=CGContext(consumer:consumer,mediaBox:&media,nil)!
  ctx.beginPDFPage(nil);ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(media)
  ctx.translateBy(x:0,y:700);ctx.scaleBy(x:1,y:-1)
  NativeTranslationTypography.draw(layout:layout,in:ctx,at:CGPoint(x:unit(pads[3]),y:unit(pads[0])),pixelSnapScale:2)
  ctx.endPDFPage();ctx.closePDF()
  let pdf=CommandLine.arguments[2];try (data as Data).write(to:URL(fileURLWithPath:pdf))
  let context=CGContext(data:nil,width:780,height:1400,bitsPerComponent:8,bytesPerRow:780*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:780,height:1400));context.scaleBy(x:2,y:2)
  context.drawPDFPage(CGPDFDocument(URL(fileURLWithPath:pdf) as CFURL)!.page(at:1)!)
  let image=context.makeImage()!,dest=CGImageDestinationCreateWithURL(URL(fileURLWithPath:pdf+".png") as CFURL,UTType.png.identifier as CFString,1,nil)!
  CGImageDestinationAddImage(dest,image,nil);CGImageDestinationFinalize(dest)
  let output=["glyphs":layout.glyphBounds.map{[$0.minX,$0.minY,$0.width,$0.height]},"scalarRanges":layout.rangeBounds.map{[$0.minX,$0.minY,$0.width,$0.height]}]
  try JSONSerialization.data(withJSONObject:output,options:.prettyPrinted).write(to:URL(fileURLWithPath:pdf+".geometry.json"))
 }
}
