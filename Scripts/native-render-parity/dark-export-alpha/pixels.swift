import Foundation
import CoreGraphics
import ImageIO
func load(_ path:String)->(CGImage,[UInt8]) {
 let url=URL(fileURLWithPath:path),src=CGImageSourceCreateWithURL(url as CFURL,nil)!,im=CGImageSourceCreateImageAtIndex(src,0,nil)!
 var b=[UInt8](repeating:0,count:im.width*im.height*4)
 b.withUnsafeMutableBytes { raw in let ctx=CGContext(data:raw.baseAddress,width:im.width,height:im.height,bitsPerComponent:8,bytesPerRow:im.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue)!;ctx.draw(im,in:CGRect(x:0,y:0,width:im.width,height:im.height)) }
 return(im,b)
}
let (a,ab)=load(CommandLine.arguments[1]),(_,bb)=load(CommandLine.arguments[2])
for y in 0..<a.height {for x in 0..<a.width {let i=(y*a.width+x)*4;if Array(ab[i..<i+4]) != Array(bb[i..<i+4]) {print("pixel",x,y,"web",Array(ab[i..<i+4]),"native",Array(bb[i..<i+4]))}}}
