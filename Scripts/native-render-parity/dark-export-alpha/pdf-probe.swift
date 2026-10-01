import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:CommandLine.arguments[1]) as CFURL,nil)!
let im=CGImageSourceCreateImageAtIndex(source,0,nil)!
let w=640,h=880
let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue)!
c.draw(im,in:CGRect(x:0,y:0,width:w,height:h))
let pdf=CGPDFDocument(URL(fileURLWithPath:CommandLine.arguments[2]) as CFURL)!,page=pdf.page(at:1)!,box=page.getBoxRect(.mediaBox)
c.scaleBy(x:CGFloat(w)/box.width,y:CGFloat(h)/box.height);c.drawPDFPage(page)
let out=CGImageDestinationCreateWithURL(URL(fileURLWithPath:CommandLine.arguments[3]) as CFURL,UTType.png.identifier as CFString,1,nil)!
CGImageDestinationAddImage(out,c.makeImage()!,nil);CGImageDestinationFinalize(out)
