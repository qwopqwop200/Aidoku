import CoreGraphics
import Foundation
func n(_ d:[String:Any],_ k:String,_ f:Double=0)->Double {(d[k] as? NSNumber)?.doubleValue ?? f}
func flag(_ d:[String:Any],_ k:String,_ f:Bool=false)->Bool {d[k] as? Bool ?? f}
func rect(_ a:Any?)->CGRect {let a=a as? [Double] ?? [0,0,0,0];return CGRect(x:a[0],y:a[1],width:a[2],height:a[3])}
func array(_ r:CGRect)->[Double] {[Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)]}
func run(_ j:[String:Any])->[String:Any] {
 let text=j["text"] as? String ?? "GO NOW",font=n(j,"font",10),glyph=n(j,"glyph",70),ratio=n(j,"ratio",1.2),factor=n(j,"factor",0.5)
 let plate=rect(j["plate"]),frame=rect(j["frame"]),source=rect(j["source"]),budget=NativeTypographyDisplayWidening.Budget()
 budget.pixels=Int(n(j,"budget",393216));var reads:[[Double]]=[]
 let input=NativeTypographyDisplayWidening.Input(text:text,font:font,glyph:glyph,pageGlyph:n(j,"pageGlyph",20),cap:n(j,"cap",.infinity),grown:j["grown"] as? Double,flatRoom:flag(j,"flatRoom"),rotation:flag(j,"rotated"),vertical:flag(j,"vertical"),sourceVertical:flag(j,"sourceVertical",true),allowsRecovery:flag(j,"recovery",true),wrappingScript:j["script"] as? String ?? "korean",visible:flag(j,"visible",true),ratio:ratio,strict:flag(j,"strict"),plate:plate,visiblePlate:rect(j["visiblePlate"] ?? j["plate"]),color:j["color"] as? [Double] ?? [255,255,255],frame:frame,source:source,imageWidth:Int(n(j,"iw",390)),imageHeight:Int(n(j,"ih",700)),others:(j["others"] as? [[Double]] ?? []).map(rect),foreignCards:(j["cards"] as? [[Double]] ?? []).map(rect),foreignSourceRects:(j["sources"] as? [[Double]] ?? []).map(rect))
 let result=NativeTypographyDisplayWidening.widen(input,budget:budget,advance:{Double($0.utf16.count)*$1*factor},read:{crop,w,h in
  reads.append(array(crop)+[Double(w),Double(h)])
  return (0..<w*h).flatMap {i -> [UInt8] in let c:UInt8=flag(j,"texture") && i%97==0 ? 0:255;return [c,c,c,255]}
 },measure:{p in
  let available=Double(p.box.width)-p.padding*2,words=text.split(whereSeparator:{$0.isWhitespace})
  var widths:[Double]=[],run = -1.0
  for word in words {let next=Double(word.utf16.count)*p.font*factor;if run>=0 && run+p.font*factor+next<=available {run+=p.font*factor+next}else{if run>=0{widths.append(run)};run=next}}
  if run>=0 {widths.append(run)}
  let height=Double(widths.count)*p.pitch,top=Double(p.box.midY)-height/2,width=widths.max() ?? 0
  return .init(ink:CGRect(x:Double(p.box.midX)-width/2,y:top,width:width,height:height),lineRects:[],
      scrollWidth:max(Double(p.box.width),width+p.padding*2),clientWidth:Double(p.box.width),
      scrollHeight:max(Double(p.box.height),height+p.padding*2),clientHeight:Double(p.box.height),badLineStart:flag(j,"badStart"))
 })
 var out:[String:Any]=["name":j["name"] as! String,"size":result?.proposal.font as Any? ?? NSNull(),"budget":budget.pixels,"reads":reads]
 if let result {out["box"]=array(result.proposal.box);out["ink"]=array(result.ink)}
 return out
}
@main struct Main {static func main()throws {let jobs=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]];try JSONSerialization.data(withJSONObject:jobs.map(run),options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))}}
