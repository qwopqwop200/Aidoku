import Foundation
import CoreGraphics
let pdf=CommandLine.arguments[1],output=CommandLine.arguments[2]
let context=CGContext(data:nil,width:780,height:1400,bitsPerComponent:8,bytesPerRow:780*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:780,height:1400));context.scaleBy(x:2,y:2)
context.drawPDFPage(CGPDFDocument(URL(fileURLWithPath:pdf) as CFURL)!.page(at:1)!)
try Data(bytes:context.data!,count:780*1400*4).write(to:URL(fileURLWithPath:output))
