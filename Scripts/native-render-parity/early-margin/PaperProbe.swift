import CoreGraphics
import Foundation
@main struct PaperProbe {
 static func main() throws {
 let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
 var actual:[[String:Any]]=[]
 enum Failure:Error { case source }
 for f in fixtures {
 func ds(_ v:Any?)->[Double] { (v as? [NSNumber])?.map(\.doubleValue) ?? [] }
 func rect(_ a:[Double])->CGRect { .init(x:a[0],y:a[1],width:a[2],height:a[3]) }
 func arr(_ r:CGRect)->[Double] { [Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)] }
 let input=NativeEarlyMarginPaper.Input(imageSize:.init(width:f["iw"] as! Int,height:f["ih"] as! Int),frame:rect(ds(f["frame"])),bounds:ds(f["bounds"]),auxiliary:(f["auxiliary"] as! [[NSNumber]]).map{ $0.map(\.doubleValue) },otherBounds:(f["excluded"] as! [[NSNumber]]).map{ $0.map(\.doubleValue) },sourceFontSize:(f["sourceFont"] as? NSNumber)?.doubleValue,fontSize:(f["font"] as! NSNumber).doubleValue,vertical:f["vertical"] as! Bool,singleColumn:f["single"] as! Bool)
 var remaining=f["budget"] as! Int,trace:[Any]=[]
 let original=(f["original"] as! [NSNumber]).map(\.uint8Value)
 let result=NativeEarlyMarginPaper.propose(input,remaining:&remaining,read:{ crop,w,h in
 trace.append(["read",crop.minX,crop.minY,crop.width,crop.height,w,h] as [Any]);if f["readFails"] as? Bool == true { throw Failure.source };return original
 },enclosedPaper:{ _,w,h,box,aux,excluded in
 trace.append(["restore",w,h,arr(box),["auxiliary":aux.map(arr),"excluded":excluded.map(arr)]] as [Any])
 guard let p=f["repair"] as? [String:Any] else { return nil }
 return .init(rgba:(p["rgba"] as! [NSNumber]).map(\.uint8Value),safe:(p["safe"] as! [NSNumber]).map(\.uint8Value),sourceErasureVerified:p["verified"] as! Bool)
 })
 let value:Any=result.map{ ["crop":arr($0.crop),"viewport":arr($0.viewport),"core":$0.core.map(arr),"excluded":$0.excluded.map(arr),"original":$0.original,"rgba":$0.repair.rgba,"safe":$0.repair.safe,"verified":$0.repair.sourceErasureVerified,"luminance":$0.luminance] as [String:Any] } ?? NSNull()
 actual.append(["id":f["id"]!,"trace":trace,"budget":remaining,"result":value])
 }
 try JSONSerialization.data(withJSONObject:actual).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
