import Foundation
import CoreGraphics

typealias G = NativeTypographyPlateGrowth
func n(_ d: [String: Any], _ k: String, _ fallback: Double = 0) -> Double { (d[k] as? NSNumber)?.doubleValue ?? fallback }
func b(_ d: [String: Any], _ k: String, _ fallback: Bool = false) -> Bool { d[k] as? Bool ?? fallback }
func rect(_ values: Any?) -> CGRect { let a = values as? [Double] ?? [0,0,0,0]; return CGRect(x:a[0],y:a[1],width:a[2],height:a[3]) }
func boxes(_ values: Any?) -> [CGRect] { (values as? [[Double]] ?? []).map(rect) }
func array(_ r: CGRect) -> [Double] { [Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)] }
func advance(_ text: String, _ size: Double, _ factor: Double) -> Double { Double(text.utf16.count) * size * factor }
func measurement(_ p: G.Proposal, _ f: [String: Any]) -> G.Measurement {
 let factor=n(f,"factor",0.5), text=f["text"] as? String ?? "ABC", scale=p.horizontalScale
 let available=Double(p.box.width)-2*p.padding/scale
 var widths:[Double]=[],run = -1.0
 for word in text.split(whereSeparator:{$0.isWhitespace}) { let w=advance(String(word),p.font,factor)
  if run>=0 && run+advance(" ",p.font,factor)+w<=available {run+=advance(" ",p.font,factor)+w}
  else {if run>=0 {widths.append(run)};run=w}
 };if run>=0 {widths.append(run)}
 let h=Double(widths.count)*p.pitch,top=Double(p.box.midY)-h/2
 let lines=widths.enumerated().map { i,w in CGRect(x:Double(p.box.midX)-w*scale/2,y:top+Double(i)*p.pitch,width:w*scale,height:p.pitch) }
 let ink=lines.reduce(CGRect.null){$0.union($1)}
 return G.Measurement(ink:ink,lineRects:lines,scrollWidth:max(Double(p.box.width),(widths.max() ?? 0)+2*p.padding/scale),clientWidth:Double(p.box.width),scrollHeight:max(Double(p.box.height),h+2*p.padding),clientHeight:Double(p.box.height),badLineStart:b(f,"badStart"),loneSyllableLines:Int(n(f,"lone")))
}
func run(_ f: [String:Any]) -> [String:Any] {
 let font=n(f,"font",12),glyph=n(f,"glyph",20),text=f["text"] as? String ?? "ABC"
 let e=G.Input(text:text,font:font,originalFont:n(f,"originalFont",font),sourceGlyph:glyph,cap:n(f,"cap",Double.infinity),styleGlyph:n(f,"styleGlyph"),ratio:n(f,"ratio",1.2),wrappingScript:f["script"] as? String ?? "korean",vertical:b(f,"vertical"),rotated:b(f,"rotated"),allowsRecovery:b(f,"recovery",true),visible:b(f,"visible",true),plateVisible:b(f,"plateVisible",true),condensedOnly:b(f,"condensed"),committedAllowed:b(f,"committedAllowed",true),strict:b(f,"strict"),loneBefore:Int(n(f,"loneBefore")),plate:rect(f["plate"]),currentInk:rect(f["ink"]),coverage:f["coverage"] == nil ? nil : boxes(f["coverage"]),frame:f["frame"] == nil ? nil : rect(f["frame"]),others:boxes(f["others"]),foreignPlates:boxes(f["foreignPlates"]),foreignCards:boxes(f["cards"]))
 let state=G.State(),budget=G.Budget();budget.roomLayouts=Int(n(f,"roomLayouts"));budget.liftLayouts=Int(n(f,"liftLayouts"))
 var roomReads=0
 let result=G.grow(e,state:state,budget:budget,advance:{advance($0,$1,n(f,"factor",0.5))},measure:{measurement($0,f)},roomProvider:{_,_ in
  roomReads+=1;guard f["room"] != nil else {return nil};let room=rect(f["room"]),blocked=boxes(f["blocked"])
  return G.Room(bounds:room,free:{r in r.minX>=room.minX && r.maxX<=room.maxX && r.minY>=room.minY && r.maxY<=room.maxY && !blocked.contains {q in r.minX<q.maxX && r.maxX>q.minX && r.minY<q.maxY && r.maxY>q.minY}})
 })
 let s=G.schedule(font:font,originalFont:e.originalFont,glyph:glyph,styleGlyph:e.styleGlyph,cap:e.cap,korean:e.wrappingScript=="korean",committed:e.condensedOnly)
 var out:[String:Any]=["name":f["name"] as? String ?? "", "schedule":["target":s.target,"display":s.display,"earlier":s.earlier,"lifts":s.lifts,"sizes":s.sizes],"roomLayouts":budget.roomLayouts,"liftLayouts":budget.liftLayouts,"roomReads":roomReads,"size":NSNull()]
 if let r=result {out["size"]=r.proposal.font;out["box"]=array(r.proposal.box);out["ink"]=array(r.measurement.ink);out["plate"]=array(r.plate);out["coverage"]=r.coverage?.map(array) ?? [];out["flatRoom"]=r.flatRoom ?? [];out["scale"]=r.proposal.horizontalScale}
 return out
}
@main struct Main { static func main() throws {
let input=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]));let fixtures=try JSONSerialization.jsonObject(with:input) as! [[String:Any]]
let result=fixtures.map(run);try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))

}}
