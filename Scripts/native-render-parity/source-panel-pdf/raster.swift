import Foundation
import CoreGraphics
import ImageIO
for file in CommandLine.arguments.dropFirst() {
 let url=URL(fileURLWithPath:file),doc=CGPDFDocument(url as CFURL)!,page=doc.page(at:1)!,box=page.getBoxRect(.mediaBox)
 let ctx=CGContext(data:nil,width:3192,height:2254,bitsPerComponent:8,bytesPerRow:3192*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(CGRect(x:0,y:0,width:3192,height:2254));ctx.scaleBy(x:3192/box.width,y:2254/box.height);ctx.drawPDFPage(page)
 let d=CGImageDestinationCreateWithURL(url.deletingPathExtension().appendingPathExtension("png") as CFURL,"public.png" as CFString,1,nil)!;CGImageDestinationAddImage(d,ctx.makeImage()!,nil);CGImageDestinationFinalize(d)
}
