import Foundation
import CoreGraphics
import CoreText
let capture = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
var results:[[String:Any]]=[]
for fixture in capture["cases"] as! [[String:Any]] {
 let input=fixture["input"] as! [String:Any],text=input["text"] as! String,requested=input["font"] as! Double
 let variants=["original":requested,"float32":Double(Float(requested)),"inline":Double((fixture["inline"] as! String).dropLast(2))!,"computed":Double((fixture["computed"] as! String).dropLast(2))!]
 var metrics:[String:Any]=[:]
 for (key,size) in variants {
  let font=CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString,size,nil)
  let attrs=NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTKernAttributeName as String):0])
  let line=CTLineCreateWithAttributedString(attrs),bounds=CTLineGetBoundsWithOptions(line,[.useGlyphPathBounds])
  metrics[key]=["fontSize":CTFontGetSize(font),"width":CTLineGetTypographicBounds(line,nil,nil,nil),"ascent":CTFontGetAscent(font),"descent":CTFontGetDescent(font),"glyphBounds":[bounds.minX,bounds.minY,bounds.width,bounds.height]]
 }
 results.append(["input":input,"metrics":metrics])
}
print(String(data:try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
