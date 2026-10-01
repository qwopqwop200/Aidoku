import Foundation
import CoreGraphics
import CryptoKit
@main struct StackProbe {
 static func main() throws {
  let jobs=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
  func rect(_ r:[Double])->CGRect {CGRect(x:r[0],y:r[1],width:r[2],height:r[3])}
  func hash(_ b:[UInt8])->String {SHA256.hash(data:Data(b)).map {String(format:"%02x",$0)}.joined()}
  var output:[[String:Any]]=[]
  for j in jobs {
   let text=j["text"] as! String,font=j["font"] as! Double,spacing=j["spacing"] as! Double,ratio=j["ratio"] as! Double,center=j["center"] as! [Double],size=j["nodeSize"] as! [Double],angle=j["angle"] as! Double,condense=j["condense"] as! Double
   let rows=(j["rows"] as! [[String:Any]]).map { r ->NativeKoreanStackRepair.Row in let b=r["rect"] as! [Double];return .init(first:r["first"] as! Int,last:r["last"] as! Int,chars:r["chars"] as! String,rect:rect([b[0],b[1],b[2]-b[0],b[3]-b[1]]))}
   let f=j["frame"] as! [Double],frame=rect(f),plates=j["plates"] as! [[String:Any]],own=plates.filter { $0["own"] as! Bool }
   var kept:[CGRect]=[]
   for p in own where p["rotated"] as? Bool != true {
    kept.append(rows.map(\.rect).reduce(CGRect.null){$0.union($1)}.offsetBy(dx:center[0],dy:center[1]))
    if let b=j["source"] as? [Double] {kept.append(rect([f[0]+b[0]*f[2],f[1]+b[1]*f[3],b[2]*f[2],b[3]*f[3]]))}
   }
   let obstacleRects=j["obstacleRects"] as! [[Double]]
   var obstacleBoxes=plates.filter { !($0["own"] as! Bool) }.map { $0["rect"] as! [Double] }
   obstacleBoxes += obstacleRects.map { b -> [Double] in [b[0]-1,b[1]-1,b[2]+2,b[3]+2] }
   let obstacles=obstacleBoxes.map { b -> [[Double]] in let right=b[0]+b[2],bottom=b[1]+b[3];return [[b[0],b[1]],[right,b[1]],[right,bottom],[b[0],bottom]] }
   var layouts:[[Any]]=[],measurements:[[Any]]=[],crops:[[Double]]=[],rasters:[String]=[]
   func measure(_ t:String,_ s:Double)->Double {measurements.append([t,s]);return t.unicodeScalars.reduce(0.0){$0+($1 == " " ? s/2:s)}}
   let nodeRect=rect([center[0]-size[0]/2,center[1]-size[1]/2,size[0],size[1]])
   let corners=NativeSlantedGeometry.rotatedCard(cx:center[0],cy:center[1],width:size[0]*condense,height:size[1],angle:angle)
   let outer=CGRect(x:corners.map{$0[0]}.min()!,y:corners.map{$0[1]}.min()!,width:corners.map{$0[0]}.max()!-corners.map{$0[0]}.min()!,height:corners.map{$0[1]}.max()!-corners.map{$0[1]}.min()!)
   let entry=NativeKoreanStackRepair.Entry(id:"a",text:text,rows:rows,font:font,ratio:ratio,spacing:spacing,angle:angle,condense:condense,center:CGPoint(x:center[0],y:center[1]),nodeRect:nodeRect,outerHeight:angle == 0 ? size[1] : Double(outer.height),frame:frame,sourcePixelWidth:j["sourceWidth"] as! Double,unit:j["unit"] as! Bool,obstacles:obstacles,kept:kept,ownColors:own.map {$0["color"] as! [Double]})
   let session=NativeKoreanStackRepair.Session()
   var style=NativeTranslationTypography.Style(fontScript:"korean",fontSize:font,vertical:false,foreground:CGColor(gray:0,alpha:1),tracking:font*spacing,lineHeight:font*ratio)
   style.koreanQuoteMode=0
   let outcome=NativeKoreanStackRepair.search(entry,session:session,measure:measure,lineLayout:{t,w,max,width in
    let lines=withoutActuallyEscaping(width) { safe in NativeTranslationTypography.koreanLines(text:t,available:CGSize(width:w,height:10000),style:style,maxLines:max,measuresScalars:true,width:{CGFloat(safe($0))}) };layouts.append([t,w,max,lines as Any? ?? NSNull()]);return lines
   },reduplication:{NativeTypographyPostPolish.reduplicationBreak(text:text,offset:$0)},read:{crop in
    let nw=j["sourceWidth"] as! Double,nh=nw*f[3]/f[2]
    crops.append([(crop.rect.minX-f[0])/f[2]*nw,(crop.rect.minY-f[1])/f[3]*nh,crop.rect.width/f[2]*nw,crop.rect.height/f[3]*nh,Double(crop.width),Double(crop.height)])
    let bg=j["background"] as! [Double],art=j["art"] as! [[Double]];var page=[UInt8](repeating:0,count:crop.width*crop.height*4)
    for y in 0..<crop.height {for x in 0..<crop.width {let px=crop.rect.minX+(Double(x)+0.5)/Double(crop.width)*crop.rect.width,py=crop.rect.minY+(Double(y)+0.5)/Double(crop.height)*crop.rect.height,r=art.last {px >= $0[0] && py >= $0[1] && px<$0[0]+$0[2] && py<$0[1]+$0[3]},color=r.map {Array($0.suffix(4))} ?? bg;for ch in 0..<4 {page[(y*crop.width+x)*4+ch]=UInt8(color[ch])}}}
    if !kept.isEmpty {rasters.append(hash(page))}
    var data=page
    for p in own {let b=p["rect"] as! [Double],color=p["color"] as! [Double];for y in 0..<crop.height {for x in 0..<crop.width {let px=crop.rect.minX+(Double(x)+0.5)/crop.scale,py=crop.rect.minY+(Double(y)+0.5)/crop.scale;if px>=b[0] && py>=b[1] && px<=b[0]+b[2] && py<=b[1]+b[3] {let i=(y*crop.width+x)*4;for ch in 0..<3 {data[i+ch]=UInt8(color[ch])};data[i+3]=255}}}}
    rasters.append(hash(data));return .init(data:data,page:kept.isEmpty ? nil:page)
   },clips:{p in
    if let c=j["clip"] as? [Double],!rect(c).contains(p) {return false}
    return own.allSatisfy { q in if q["rotated"] as? Bool == true {return true};return rect(q["rect"] as! [Double]).insetBy(dx:-0.5,dy:-0.5).contains(p) }
   },verify:{_ in true})
   var repair:Any=NSNull(),declined:Any=NSNull()
   if let c=outcome.candidate {repair=[c.kind,font,c.font,c.condense,Double(rows.count),Double(c.lines.count),floor(size[0]+0.5),floor(c.width*c.condense+0.5)] as [Any]}
   if outcome.declined {var r:[String:Any]=outcome.rejected;if let best=outcome.best {r["best"]=best;r["ref"]=outcome.reference};declined=[NativeKoreanStackRepair.kind(text:text,rows:rows,unit:j["unit"] as! Bool,reduplication:{NativeTypographyPostPolish.reduplicationBreak(text:text,offset:$0)})!,r]}
   output.append(["repair":repair,"declined":declined,"layouts":layouts,"measurements":measurements,"crops":crops,"rasters":rasters])
  }
  try JSONSerialization.data(withJSONObject:output,options:.sortedKeys).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
