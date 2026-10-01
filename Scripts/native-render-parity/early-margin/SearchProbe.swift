import CoreGraphics
import Foundation
@main struct SearchProbe {
 static func main() throws {
 let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
 var actual:[[String:Any]]=[]
 for f in fixtures {
 func n(_ k:String)->CGFloat { CGFloat((f[k] as! NSNumber).doubleValue) }
 func point(_ k:String)->CGPoint { let a=f[k] as! [NSNumber];return .init(x:a[0].doubleValue,y:a[1].doubleValue) }
 let input=NativeEarlyBalloonSearch.Input(id:f["id"] as! String,font:n("font"),priorFont:n("prior"),minimum:n("minimum"),sourceGlyph:n("glyph"),sourceWidth:n("sourceWidth"),baseWidth:n("baseWidth"),sourceCentre:point("source"),originalCentre:point("original"),offsetSearch:f["offset"] as! Bool,provisional:f["provisional"] as! Bool,auxiliaryOriginalPreserved:f["aux"] as! Bool)
 let session=NativeEarlyBalloonSearch.Session();var trace:[[CGFloat]]=[]
 let result:NativeEarlyBalloonSearch.Accepted<Bool>?=NativeEarlyBalloonSearch.run(input,session:session,
 fontSizes:{NativeBalloonFontsHost.balloonFontSizes(font:$0,minimum:$1)},restoredFloor:{NativeBalloonFontsHost.restoredFontFloor(original:$0,minimum:$1)},emergencySizes:{NativeBalloonFontsHost.emergencyBalloonFontSizes(font:$0,minimum:$1,preferred:$2)},lineWidth:{_ in .infinity},wordWidth:{$0*n("word")},makeGrid:{nil},layout:{size,anchor,width,_ in
 trace.append([size,anchor.x,anchor.y,width]);let frame=CGRect(x:anchor.x-width/2,y:anchor.y-size/2,width:width,height:size)
 let target=point("target"),passes=size<=n("maximum") && width>=n("minWidth") && abs(anchor.x-target.x)<=n("radius") && abs(anchor.y-target.y)<=n("radius")
 return .init(frame:frame,value:passes ? true:nil,rank:width<n("cleanWidth") ? 100:0)
 })
 let chosen:Any=result.map{ ["size":$0.size,"wordFlow":$0.wordFlow,"emergency":$0.emergency] as [String:Any] } ?? NSNull()
 let frames:Any=result == nil ? (session.centreFrames[input.id] ?? [:]).map { key,value -> [Any] in
 let canonical=key.split(separator:"|").map { String(format:"%.15g",Double($0)!) }.joined(separator:"|")
 return [canonical,[value.minX,value.minY,value.width,value.height]]
 }.sorted { ($0[0] as! String)<($1[0] as! String) }:NSNull()
 actual.append(["id":f["id"]!,"accepted":result != nil,"trace":trace,"chosen":chosen,"frames":frames])
 }
 try JSONSerialization.data(withJSONObject:actual).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
