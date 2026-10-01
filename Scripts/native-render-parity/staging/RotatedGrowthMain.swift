import CoreGraphics
import Foundation
func n(_ d:[String:Any],_ k:String,_ f:Double=0)->Double {(d[k] as? NSNumber)?.doubleValue ?? f}
func flag(_ d:[String:Any],_ k:String,_ f:Bool=false)->Bool {d[k] as? Bool ?? f}
func rect(_ a:Any?)->CGRect {let a=a as? [Double] ?? [0,0,0,0];return CGRect(x:a[0],y:a[1],width:a[2],height:a[3])}
func array(_ r:CGRect)->[Double] {[Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)]}
typealias G=NativeTypographyRotatedGrowth
func run(_ j:[String:Any])->[String:Any] {
 let text=j["text"] as? String ?? "ONE TWO",font=n(j,"font",12),glyph=n(j,"glyph",24),ratio=n(j,"ratio",1.2),factor=n(j,"factor",0.45),box=rect(j["box"]),angle=n(j,"angle",0.2)
 func metrics(_ size:Double)->G.FontMetrics {.init(fontAscent:size*0.8,fontDescent:size*0.2,actualAscent:size*0.75,actualDescent:size*0.15,actualLeft:size*0.02,actualRight:Double(text.utf16.count)*size*factor,advance:Double(text.utf16.count)*size*factor)}
 func physical(_ t:G.Trial)->G.Measurement {
  let side=t.side==0 ? n(j,"padding",2):t.side,available=(Double(box.width)-2*side)/t.scale
  var widths:[Double]=[],run = -1.0
  for word in text.split(whereSeparator:{$0.isWhitespace}) {let next=Double(word.utf16.count)*t.font*factor;if run>=0 && run+t.font*factor+next<=available {run+=t.font*factor+next}else{if run>=0{widths.append(run)};run=next}}
  if run>=0 {widths.append(run)}
  let height=Double(widths.count)*t.pitch,top=Double(box.midY)-height/2+(t.pitch-t.font)/2+t.shift
  let rows=widths.enumerated().map {i,w in CGRect(x:Double(box.midX)-w*t.scale/2,y:top+Double(i)*t.pitch,width:w*t.scale,height:t.font)}
  let ink=rows.reduce(CGRect.null) {$0.union($1)}
  return .init(rows:rows,ink:ink,scrollWidth:max(Double(box.width)/t.scale,(widths.max() ?? 0)+2*side/t.scale),clientWidth:Double(box.width)/t.scale,
    scrollHeight:max(Double(box.height),height+abs(t.shift)*2),clientHeight:Double(box.height),badLineStart:flag(j,"badStart"))
 }
 let original=physical(.init(font:font,side:n(j,"padding",2),scale:1,pitch:font*ratio,shift:0))
 let effective=flag(j,"upright") ? 0:angle
 let peers=(j["peers"] as? [[String:Any]] ?? []).map {d in G.Peer(text:d["text"] as? String ?? "",script:d["script"] as? String ?? "korean",glyph:n(d,"glyph"),font:n(d,"font"),source:d["source"]==nil ? nil:rect(d["source"]),visible:flag(d,"visible",true))}
 let others=(j["others"] as? [[Double]] ?? []).map(rect),groups=(j["groups"] as? [[[Double]]] ?? []).map {rs in rs.map {NativeSlantedGeometry.rotatedCard(cx:$0[0]+$0[2]/2,cy:$0[1]+$0[3]/2,width:$0[2],height:$0[3],angle:0)}}
 let input=G.Input(text:text,script:j["script"] as? String ?? "korean",font:font,glyph:glyph,box:box,source:rect(j["source"] ?? j["box"]),itemBox:box,rotation:angle,upright:flag(j,"upright"),cap:n(j,"cap",.infinity),ratio:ratio,strict:flag(j,"strict"),rotatingPanel:flag(j,"rotatingPanel",true),backgroundKind:j["backgroundKind"] as? String ?? "rotated-panel",vertical:flag(j,"vertical"),wrappingScript:j["wrap"] as? String ?? "korean",visible:flag(j,"visible",true),plainText:flag(j,"plainText",true),opaque:flag(j,"opaque",true),originalRows:original.rows,originalPageInk:G.painted(original.ink,box:box,angle:effective).rect,peers:peers,otherLinePolygons:groups,others:others,foreignCards:(j["cards"] as? [[Double]] ?? []).map(rect))
 let result=G.grow(input,advance:{Double($0.utf16.count)*$1*factor},metrics:{metrics($0)},measure:{physical($0)},convexOverlap:flag(j,"noConvex") ? nil:NativeSlantedGeometry.convexOverlap,containsUpright:{ink in
  let quad=NativeSlantedGeometry.rotatedCard(cx:Double(box.midX),cy:Double(box.midY),width:Double(box.width),height:Double(box.height),angle:angle,margin:2)
  return [[Double(ink.minX),Double(ink.minY)],[Double(ink.maxX),Double(ink.minY)],[Double(ink.maxX),Double(ink.maxY)],[Double(ink.minX),Double(ink.maxY)]].allSatisfy {NativeSlantedGeometry.pointInConvex(quad,point:$0)}
 })
 var out:[String:Any]=["name":j["name"] as! String,"size":result?.trial.font as Any? ?? NSNull()]
 if let r=result {out["body"]=r.body;out["scale"]=r.trial.scale;out["pitch"]=r.trial.pitch;out["shift"]=r.trial.shift;out["ink"]=array(r.pageInk)}
 return out
}
@main struct Main {static func main()throws {let jobs=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]];try JSONSerialization.data(withJSONObject:jobs.map(run),options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))}}
