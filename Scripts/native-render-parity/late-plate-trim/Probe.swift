import CoreGraphics
import Foundation
func ds(_ any:Any?) -> [Double] { (any as? [NSNumber])?.map(\.doubleValue) ?? [] }
func rect(_ any:Any?) -> CGRect { let a=ds(any);return .init(x:a[0],y:a[1],width:a[2],height:a[3]) }
func ar(_ r:CGRect)->[Double] { [Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)] }
func num(_ any:Any?,_ fallback:Double)->Double { (any as? NSNumber)?.doubleValue ?? fallback }
func flag(_ any:Any?,_ fallback:Bool=false)->Bool { any as? Bool ?? fallback }
let inputs=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
var outputs:[[String:Any]]=[]
for f in inputs {
 let flags=f["flags"] as! [String:Any],validation=f["validation"] as! [String:Any],rgba=(f["rgba"] as! [NSNumber]).map(\.uint8Value),width=Int(num(f["width"],0)),height=Int(num(f["height"],0))
 let source=NativeLatePlateTrim.Source(id:"one",bounds:ds(f["bounds"]),auxiliary:(f["auxiliary"] as? [[NSNumber]])?.map { $0.map(\.doubleValue) } ?? [],font:(f["sourceFont"] as? NSNumber)?.doubleValue,vertical:flag(f["vertical"]),rotation:num(f["rotation"],0))
 let caption=NativeLatePlateTrim.Caption(ink:rect(f["ink"]),font:num(f["font"],16),visible:!flag(flags["hidden"]),transformed:flag(flags["captionTransformed"]),displayCardGrowth:flag(flags["displayCardGrowth"]),sampledForeground:f["foreground"] is NSNull ? nil:ds(f["foreground"]),sampledStroke:nil,outlined:f["outlined"] as? [String:Any],sample:f["sample"] as? [String:Any] ?? [:])
 let coverage=(f["coverage"] as? [[NSNumber]])?.map { rect($0) }
 let plate=NativeLatePlateTrim.Plate(rect:rect(f["plate"]),coverage:coverage,background:ds(f["plateRGB"]),sourceErasure:flag(flags["sourceErasure"]),sourcePreservedCaption:flag(flags["sourcePreservedCaption"]),transformed:flag(flags["transformed"]),visible:!flag(flags["hidden"]),hasBackgroundImage:flag(flags["hasBackgroundImage"]),hasBacking:flag(flags["hasBacking"]),otherChildren:flag(flags["otherChildren"]),clipped:flag(flags["clippedWithoutCoverage"]))
 let scene=NativeLatePlateTrim.Scene(opacity:num(f["opacity"],1),itemCount:1+(f["others"] as! [Any]).count,frame:rect(f["frame"]),imageSize:.init(width:width,height:height),imageComplete:flag(f["imageComplete"],true))
 let others=(f["others"] as! [[String:Any]]).map { NativeLatePlateTrim.Source(id:$0["id"] as! String,bounds:ds($0["bounds"]),auxiliary:[],font:($0["font"] as? NSNumber)?.doubleValue,vertical:flag($0["vertical"])) }
 let budget=NativeLatePlateTrim.Budget();budget.samples=Int(num(f["budget"],1_048_576));var calls:[[Int]]=[]
 let result=NativeLatePlateTrim.trim(source:source,caption:caption,plate:plate,scene:scene,budget:budget,otherSources:others,otherCaptionInks:(f["otherInks"] as! [Any]).map(rect),restoration:f["restoration"].map(rect),readSource:{ crop,w,h in
  let x=Int(crop.minX),y=Int(crop.minY);calls.append([x,y,w,h]);if flag(f["throwRead"]) { throw NSError(domain:"read",code:1) }
  var out=[UInt8](repeating:0,count:w*h*4);for yy in 0..<h { for xx in 0..<w { for c in 0..<4 { out[(yy*w+xx)*4+c]=rgba[((y+yy)*width+x+xx)*4+c] } } };return out
 },validate:{ p in
  let d=num(validation["shift"],0);return .init(ink:caption.ink.offsetBy(dx:d,dy:d),fits:flag(validation["fits"],true),clipSupported:!p.clipped || flag(validation["clipSupported"],true))
 })
 let r:Any=result.map { ["rect":ar($0.rect),"coverage":$0.coverage.map { $0.map(ar) } as Any? ?? NSNull(),"clipped":$0.clipped,"areas":[$0.oldArea,$0.newArea]] as [String:Any] } ?? NSNull()
 outputs.append(["id":f["id"]!,"result":r,"budget":budget.samples,"calls":calls,"error":NSNull()])
}
try JSONSerialization.data(withJSONObject:outputs,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
