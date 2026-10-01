import Foundation
import CoreText
let capture=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
let fixtures=capture["WKWebView"] as! [[String:Any]]
var output:[[String:Any]]=[]
for fixture in fixtures {
 let font=CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString,fixture["font"] as! Double,nil)
 let tracking=fixture["tracking"] as! Double
 let text=fixture["text"] as! String,source=text as NSString,n=source.length
 let nativeAnalysis=NativeNormalBreakOpportunities.analyze(text:text)
 let primaryOffsets=nativeAnalysis?.items.map { NSMaxRange($0.range) } ?? []
 let table=Dictionary(uniqueKeysWithValues:(fixture["widths"] as! [[Double]]).map{(Int($0[0])*(n+1)+Int($0[1]),Float($0[2]))})
 var record:[String:Any]=["id":(fixture["input"] as! [String:Any])["id"]!,"text":text,"width":fixture["width"]!,"nativePrimaryOffsets":primaryOffsets,"referencePrimaryOffsets":fixture["primaryOffsets"]!,"auto":fixture["auto"]!,"web":fixture["balanced"]!]
 for mode in ["canvas","coretext"] {
  func measure(_ range:NSRange)->Float {
   if mode=="canvas" { return table[range.location*(n+1)+range.length]! }
   let string=NSAttributedString(string:source.substring(with:range),attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTKernAttributeName as String):tracking])
   return Float(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(string),nil,nil,nil))
  }
  let result=NativeNormalTextFlow.layout(text:text,maximumWidth:CGFloat(fixture["width"] as! Double),balances:true,width:{CGFloat(measure($0))},emergencyBreak:{range,available in
    var end=range.location,chosen=0
    while end<NSMaxRange(range) {
     end=NSMaxRange(source.rangeOfComposedCharacterSequence(at:end))
     if CGFloat(measure(NSRange(location:range.location,length:end-range.location)))>available {break}
     chosen=end-range.location
    }
    return chosen
  })
  let greedy=result?.autoRanges
  record[mode]=["greedy":greedy?.map{[$0.location,$0.length]} as Any? ?? NSNull(),"ranges":(result?.sourceRanges ?? []).map{[$0.location,$0.length]},"accepted":result != nil,
    "displayRows":result?.displayRows ?? []]
 }
 output.append(record)
}
print(String(data:try JSONSerialization.data(withJSONObject:output),encoding:.utf8)!)
