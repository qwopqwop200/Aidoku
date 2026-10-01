import CoreGraphics
import Foundation
func d(_ value:Any?)->[Double] { (value as? [NSNumber])?.map(\.doubleValue) ?? [] }
func b(_ value:Any?,_ fallback:Bool=true)->Bool { value as? Bool ?? fallback }
func canvas(_ f:[String:Any])->NativeEarlyMarginPixels.Canvas {
 let w=f["w"] as! Int,h=f["h"] as! Int,frame=d(f["frame"]),image=d(f["imageSize"]),origin=d(f["origin"]),scale=d(f["scale"])
 return .init(id:f["id"] as! String,width:w,height:h,rgba:(f["rgba"] as! [NSNumber]).map(\.uint8Value),safe:(f["safe"] as! [NSNumber]).map(\.uint8Value),luminance:(f["luminance"] as! [NSNumber]).map(\.uint8Value),geometry:.init(frame:.init(x:frame[0],y:frame[1],width:frame[2],height:frame[3]),imageSize:.init(width:image[0],height:image[1]),origin:.init(x:origin[0],y:origin[1]),scale:.init(width:scale[0],height:scale[1])),erasureComplete:b(f["complete"]),erasureVerified:b(f["verified"]),connected:b(f["connected"]),rootOwned:b(f["rootOwned"]),provisional:b(f["provisional"],false))
}
let fs=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
var out:[[String:Any]]=[]
for f in fs {
 let c=canvas(f["canvas"] as! [String:Any]),budget=NativeEarlyMarginPixels.Budget(artworkSurfaceRemaining:262144)
 if f["op"] as! String == "exterior" {
  budget.exterior=f["budget"] as! Int
  let result=NativeEarlyMarginPixels.exterior(c,core:(f["core"] as! [[NSNumber]]).map { $0.map(\.doubleValue) },glyph:(f["glyph"] as! NSNumber).doubleValue,budget:budget)
  out.append(["id":f["id"]!,"result":result.map { ["safe":$0.safe,"ignored":$0.ignored,"components":$0.components] as [String:Any] } as Any? ?? NSNull(),"budget":budget.exterior])
 } else {
  budget.certification=f["budget"] as! Int
  let donors=(f["donors"] as! [[String:Any]]).map(canvas)
  let result=NativeEarlyMarginPixels.reconcile(c,donors:donors,budget:budget)
  if b(f["repeat"],false) {
   var current=c
   if let result { current.safe=result.safe;current.luminance=result.luminance }
   _ = NativeEarlyMarginPixels.reconcile(current,donors:donors.map { $0.id==c.id ? current:$0 },budget:budget)
  }
  let revision=(f["canvas"] as! [String:Any])["revision"] as! Int
  out.append(["id":f["id"]!,"result":result.map { ["safe":$0.safe,"luminance":$0.luminance,"added":$0.added,"revision":revision+1] as [String:Any] } as Any? ?? NSNull(),"budget":budget.certification,"cache":donors.filter { budget.groupPixels[$0.id] != nil }.map(\.id)])
 }
}
try JSONSerialization.data(withJSONObject:out).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
