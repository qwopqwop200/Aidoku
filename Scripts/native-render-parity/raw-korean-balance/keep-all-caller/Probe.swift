import Foundation
import CoreText
let capture=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
let fixtures=capture["WKWebView"] as! [[String:Any]]
let font=CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString,16,nil)
var output:[[String:Any]]=[]
for fixture in fixtures {
 let text=fixture["text"] as! String,source=text as NSString,n=source.length
 let auto=(fixture["auto"] as! [[Int]]).map{NSRange(location:$0[0],length:$0[1])}
 let table=Dictionary(uniqueKeysWithValues:(fixture["widths"] as! [[Double]]).map{(Int($0[0])*(n+1)+Int($0[1]),Float($0[2]))})
 var record:[String:Any]=["text":text,"width":fixture["width"]!,"auto":fixture["auto"]!,"web":fixture["balanced"]!]
 for mode in ["canvas","coretext"] {
  func measure(_ range:NSRange)->Float {
   if mode=="canvas" { return table[range.location*(n+1)+range.length]! }
   let string=NSAttributedString(string:source.substring(with:range),attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font])
   return Float(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(string),nil,nil,nil))
  }
  let result=NativeKeepAllTextBalance.solve(text:text,originalAutoRanges:auto,maximumWidth:CGFloat(fixture["width"] as! Double),itemWidth:measure)
  record[mode]=["ranges":(result?.flowRanges ?? auto).map{[$0.location,$0.length]},"accepted":result != nil,
    "lineWidths":result?.lineWidths ?? [],"originalWidths":result?.originalLineWidths ?? []]
 }
 output.append(record)
}
print(String(data:try JSONSerialization.data(withJSONObject:output),encoding:.utf8)!)
