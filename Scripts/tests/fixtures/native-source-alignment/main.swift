import Foundation
import CoreGraphics
let values=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
func rect(_ x:Any?)->CGRect {let a=x as? [Double] ?? [0,0,0,0];return CGRect(x:a[0],y:a[1],width:a[2],height:a[3])}
func array(_ r:CGRect)->[Double] {[Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)]}
func number(_ d:[String:Any],_ k:String,_ fallback:Double)->Double {d[k] as? Double ?? fallback}
let output=values.map {f -> [String:Any] in
 let frame=rect(f["frame"]),rs=f["records"] as! [[String:Any]]
 let entries=rs.map {r -> NativeTranslationSourceAlignment.Entry in
  let lines=(r["lines"] as! [[Double]]).map(rect),ink=lines.reduce(CGRect.null) {$0.union($1)}
  var e=NativeTranslationSourceAlignment.Entry(id:r["id"] as! String,text:r["text"] as! String,renderedText:r["rendered"] as? String ?? r["text"] as! String,source:rect(r["source"]),font:number(r,"font",10),sourceFont:r["sourceFont"] as? Double,lines:lines,ink:ink,nodeRect:rect(r["box"]))
  e.visible=r["visible"] as? Bool ?? true;e.horizontalWriting=r["horizontal"] as? Bool ?? true;e.sourceRotation=r["sourceRotation"] as? Bool ?? false;e.rtl=r["rtl"] as? Bool ?? false;e.transformNone=r["transform"] as? Bool ?? true;e.hasScale=r["scale"] as? Bool ?? false;e.sourceVertical=r["sourceVertical"] as? Bool ?? false;e.rotation=number(r,"rotation",0);e.automaticRecovery=r["automatic"] as? Bool ?? true
  e.children=r["unsupported"] as? Bool == true ? .unsupported:r["spans"] as? Bool == true ? .blockSpans:.plain;e.wrap=r["wrap"] as? String ?? "balance";e.isRoot=r["root"] as? Bool ?? true;e.backgroundKind=r["background"] as? String ?? "inpainted";e.sampledForeground=r["fg"] as? [Double];e.sampledBackground=r["bg"] as? [Double];e.sourcePanelCoverage=(r["coverage"] as? [[Double]])?.map(rect);e.paintsBackground=r["paint"] as? Bool ?? false;e.hasBackgroundImage=r["image"] as? Bool ?? false
  return e
 }
 let pixels=f["pixels"] as? [[Double]] ?? []
 let reader:NativeTranslationSourceAlignment.Reader={crop,w,h in
  var rgba=[UInt8](repeating:255,count:w*h*4)
  for y in 0..<h {for x in 0..<w {
   let px=crop.minX+(CGFloat(x)+0.5)*crop.width/CGFloat(w),py=crop.minY+(CGFloat(y)+0.5)*crop.height/CGFloat(h)
   if pixels.contains(where:{v in let r=rect(v);return px>=r.minX && px<r.maxX && py>=r.minY && py<r.maxY}) {for c in 0..<3 {rgba[(y*w+x)*4+c]=0}}
  }};return rgba
 }
 let plates=(f["plates"] as? [[String:Any]] ?? []).map {p in NativeTranslationSourceAlignment.Plate(rect:rect(p["rect"]),coverage:(p["coverage"] as? [[Double]])?.map(rect),parent:p["parent"] as? Bool ?? false,ownerID:p["id"] as! String)}
 let result=NativeTranslationSourceAlignment.apply(entries,frame:frame,sourcePixelWidth:Int(number(f,"pixelWidth",400)),plates:plates,pixelBudget:Int(number(f,"budget",1_000_000)),reader:reader,shape:{e,request in
  let r=rs.first {$0["id"] as? String==e.id}!
  let key=request.mode == .heading ? "headingLines":"flushLines"
  if r["shapeFail"] as? Bool == true {return nil}
  let ls=(r[key] as? [[Double]] ?? r["lines"] as! [[Double]]).map(rect)
  let ink=ls.reduce(CGRect.null) {$0.union($1)}
  return .init(lines:ls,ink:ink,nodeRect:e.nodeRect,scrollSize:CGSize(width:e.nodeRect.width+number(r,"overflow",0),height:e.nodeRect.height+number(r,"extraHeight",0)),clientSize:e.nodeRect.size,labelRows:Int(number(r,"labelRows",1)))
 },holdsSurface:{$0.id.hasPrefix("safe")})
 return ["name":f["name"]!,"headings":result.headings,"aligned":result.aligned,"edgeMoves":result.edgeMoves,"budget":result.remainingPixels,"states":result.entries.map {e in ["id":e.id,"heading":e.heading as Any? ?? NSNull(),"alignment":e.alignment as Any? ?? NSNull(),"edge":e.edgeShift as Any? ?? NSNull(),"text":e.renderedText,"lines":e.lines.map(array),"ink":array(e.ink),"nodeRect":array(e.nodeRect),"shift":[Double(e.shift.x),Double(e.shift.y)],"wrapperWidth":e.wrapperWidth.map(Double.init) as Any? ?? NSNull(),"offsets":e.lineOffsets?.map(Double.init) as Any? ?? NSNull()]}]
}
let data=try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]);try data.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
