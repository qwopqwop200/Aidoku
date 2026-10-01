import Foundation
import CoreGraphics
func rect(_ a:[Double])->CGRect {CGRect(x:a[0],y:a[1],width:a[2],height:a[3])}
func profile(_ d:[String:Any])->NativeKoreanInlineRepair.Profile { .init(lines:d["lines"] as! Int,breaks:d["breaks"] as? [Int] ?? [],badStarts:d["starts"] as? [Int] ?? [],badEnds:d["ends"] as? [Int] ?? [],ink:(d["ink"] as? [[Double]] ?? [[2,2,10,10]]).map(rect)) }
let input=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
let output=input.map {f -> [String:Any] in
 var e=NativeKoreanInlineRepair.Entry(text:f["text"] as! String,card:rect(f["card"] as? [Double] ?? [0,0,50,50]),exclusions:(f["exclusions"] as? [[Double]] ?? []).map(rect),font:f["font"] as! Double,padding:f["padding"] as? [Double] ?? [2,2,2,2]);e.vertical=f["vertical"] as? Bool ?? false;e.wrappingScript=f["script"] as? String ?? "korean"
 var budget=f["budget"] as? Int ?? 2048;let profiles=f["profiles"] as! [String:[String:Any]]
 let result=NativeKoreanInlineRepair.repair(e,characterBudget:&budget,minimumFont:f["minimum"] as? Double ?? 5,widestWord:{_,_ in f["widest"] as? Double ?? 100},measure:{c in
  let key=c.strictPunctuation ? "strict":String(format:"%.2f",c.font)
  guard let d=profiles[key] else {return nil}
  return .init(profile:d["null"] as? Bool == true ? nil:profile(d),fits:d["fits"] as? Bool ?? true)
 })
 return ["name":f["name"]!,"font":result.candidate.font,"padding":result.candidate.padding,"strict":result.candidate.strictPunctuation,"wrap":result.wrapAccepted,"punctuation":result.punctuationAccepted,"budget":budget]
}
try JSONSerialization.data(withJSONObject:output,options:.sortedKeys).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
