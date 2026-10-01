import Foundation
import CoreText
import CoreGraphics
let capture = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
let fixtures=capture["cases"] as! [[String:Any]],out=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
for useFloat in [false,true] {
 let path=out.appendingPathComponent(useFloat ? "float32-controls.pdf":"double-controls.pdf")
 var box=CGRect(x:0,y:0,width:1600,height:1400)
 let consumer=CGDataConsumer(url:path as CFURL)!,context=CGContext(consumer:consumer,mediaBox:&box,nil)!
 context.beginPDFPage(nil)
 for (index,fixture) in fixtures.enumerated() {
  let input=fixture["input"] as! [String:Any],requested=input["font"] as! Double,text=input["text"] as! String
  let size=useFloat ? Double(Float(requested)):requested
  let font=CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString,size,nil)
  let value=NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTKernAttributeName as String):0])
  context.textMatrix = .identity;context.textPosition=CGPoint(x:20,y:1300-index*85)
  CTLineDraw(CTLineCreateWithAttributedString(value),context)
 }
 context.endPDFPage();context.closePDF()
}
