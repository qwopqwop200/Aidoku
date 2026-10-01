import CoreGraphics
import Foundation
@main struct Main {
 static func main() throws {
  let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String:Any]]
  var out:[[String:Any]]=[]
  for f in fixtures {
   func d(_ k:String,_ value:Double)->Double {(f[k] as? NSNumber)?.doubleValue ?? value}
   func b(_ k:String,_ value:Bool)->Bool {f[k] as? Bool ?? value}
   let q=f["rect"] as? [Double] ?? [100,100,60,35],text=f["text"] as? String ?? "HELLO WORDS"
   var e=NativeRotatedReadability.Entry(text:text,renderedText:f["renderedText"] as? String ?? text,rect:CGRect(x:q[0],y:q[1],width:q[2],height:q[3]),font:d("font",6),pitch:d("font",6)*1.2,scale:d("scale",1),angle:d("angle",0.2),background:[245,245,245],frame:CGRect(x:0,y:0,width:500,height:500),imageSize:CGSize(width:500,height:500))
   e.padding=[2,2,2,2];e.korean=b("korean",true);e.uprightQuad=b("upright",false);e.hasBackgroundImage=b("bgImage",false);e.opaque=b("opaque",true)
   if let p=f["peer"] as? [Double] {let top=p[1]+2+(p[3]-4-7.2)/2+0.6;let poly=NativeSlantedGeometry.rotatedCard(cx:p[0]+2+6,cy:top+3,width:12,height:6,angle:0);e.others=[poly];e.lettering=[poly]}
   var budget=NativeRotatedReadability.Budget(pixels:Int(d("pixels",786432)),layouts:Int(d("layouts",0)))
   func measure(_ c:NativeRotatedReadability.Candidate)->NativeRotatedReadability.Measurement? {
    let chars=Array(text.unicodeScalars),a=c.font*0.5,p=c.padding,avail=max(0.01,Double(c.rect.width)-p[1]-p[3]),cols=max(1,Int(floor(avail/a))),rows=max(1,Int(ceil(Double(chars.count)/Double(cols))))
    var words:[[Int]]=[[]]
    for (i,ch) in chars.enumerated() {if NativeSlantedTypographyTrial.whitespace(ch) {if !words[words.count-1].isEmpty {words.append([])}} else {words[words.count-1].append(i/cols)}}
    let broken=words.contains {Set($0).count>1};let top=p[0]+(Double(c.rect.height)-p[0]-p[2]-Double(rows)*c.pitch)/2+(c.pitch-c.font)/2
    let lead=(c.pitch-c.font)/2,ink=CGRect(x:p[3],y:top+lead,width:Double(min(cols,chars.count))*a,height:Double(rows-1)*c.pitch+c.font-2*lead)
    return .init(rows:rows,broken:broken,overflowWidth:a>avail+0.5,overflowHeight:Double(rows)*c.pitch+p[0]+p[2]>Double(c.rect.height)+0.5,ink:ink)
   }
   let result=NativeRotatedReadability.run(e,opacity:d("opacity",1),itemCount:Int(d("count",1)),budget:&budget,hooks:.init(measure:measure,longestWord:{font in text.split(whereSeparator:{$0.isWhitespace}).map{Double($0.count)*font*0.5}.max() ?? 0},read:{r in if b("noRead",false) {return nil};return Array(repeating:[UInt8](repeating:UInt8(d("paper",245)),count:3)+[255],count:Int(r.width*r.height)).flatMap{$0}}))
   var o:[String:Any]=["name":f["name"]!,"accepted":result != nil,"pixels":budget.pixels,"layouts":budget.layouts,"lifted":budget.lifted]
   if let r=result {let c=r.candidate;o["candidate"]=[c.rect.minX,c.rect.minY,c.rect.width,c.rect.height,c.font,c.pitch,c.scale,c.side];o["metadata"]=r.metadata;o["clip"]=r.clip;o["ink"]=r.ink}
   out.append(o)
  }
  try JSONSerialization.data(withJSONObject:out,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
