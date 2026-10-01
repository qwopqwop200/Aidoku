import Foundation
import AppKit
import CoreText
import CoreGraphics
import ImageIO
@main
struct VerticalPainterProbe {
 static func main() throws {
let out=URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
let blank=image {_ in}
var reports:[[String:Any]]=[]
func image(_ paint:(CGContext)->Void)->(CGImage,Data) {
 let c=CGContext(data:nil,width:960,height:308,bitsPerComponent:8,bytesPerRow:960*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 c.setFillColor(CGColor(gray:1,alpha:1));c.fill(CGRect(x:0,y:0,width:960,height:308));c.translateBy(x:0,y:308);c.scaleBy(x:2,y:-2);paint(c)
 return(c.makeImage()!,Data(bytes:c.data!,count:960*308*4))
}
for fontSize:CGFloat in [19,20,20.5,21] { for tracking:CGFloat in [-1,0,1] { for stroke:CGFloat in [0,8] {
 let paragraph=NSMutableParagraphStyle();paragraph.alignment = .center;paragraph.minimumLineHeight=24;paragraph.maximumLineHeight=24;paragraph.lineBreakMode = .byCharWrapping
 let text=NSAttributedString(string:"天地玄黄宇宙洪荒",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("PingFangSC-Semibold" as CFString,fontSize,nil),NSAttributedString.Key(kCTVerticalFormsAttributeName as String):true,.paragraphStyle:paragraph,.kern:0,NSAttributedString.Key(kCTTrackingAttributeName as String):tracking,NSAttributedString.Key(kCTStrokeWidthAttributeName as String):stroke,NSAttributedString.Key(kCTStrokeColorAttributeName as String):CGColor(gray:0,alpha:1),NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)])
 let f=CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text),CFRange(location:0,length:0),CGPath(rect:CGRect(x:0,y:0,width:480,height:154),transform:nil),[kCTFrameProgressionAttributeName:CTFrameProgression.rightToLeft.rawValue] as CFDictionary)
 let lines=CTFrameGetLines(f) as! [CTLine];var origins=[CGPoint](repeating:.zero,count:lines.count);CTFrameGetLineOrigins(f,CFRange(location:0,length:0),&origins)
 let reference=image {c in c.translateBy(x:0,y:154);c.scaleBy(x:1,y:-1);c.textMatrix = .identity;CTFrameDraw(f,c)}
 var accepted=true,state=true
 let prepared=lines.compactMap { NativeCTFontVerticalPainter.prepare(line:$0) }
 let allPrepared=prepared.count == lines.count
 let proposed=image {c in
  let initialMatrix=CGAffineTransform(rotationAngle:0.2),initialPoint=CGPoint(x:4,y:5);c.textMatrix=initialMatrix;c.textPosition=initialPoint
  guard allPrepared else {accepted=false;return}
  for (l,o) in zip(prepared,origins) {
   let ctm=c.ctm, actualMatrix=c.textMatrix, actualPoint=c.textPosition
   accepted = NativeCTFontVerticalPainter.draw(prepared:l,context:c,anchor:CGPoint(x:o.x,y:154-o.y)) && accepted
   state = state && c.textMatrix == actualMatrix && c.textPosition == actualPoint && c.ctm == ctm
  }
 }
 var changed=0,delta=0;let a=[UInt8](reference.1),b=[UInt8](proposed.1)
 for i in stride(from:0,to:a.count,by:4) {if a[i..<i+4] != b[i..<i+4] {changed += 1};for j in 0..<4 {delta=max(delta,abs(Int(a[i+j])-Int(b[i+j])))}}
 reports.append(["fontSize":fontSize,"tracking":tracking,"strokePercent":stroke,"accepted":accepted,"stateRestored":state,"refusalCanvasUntouched":accepted || proposed.1==blank.1,"changedRGBA":changed,"maxDelta":delta])
}}}
let horizontal=CTLineCreateWithAttributedString(NSAttributedString(string:"guard",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica" as CFString,20,nil)]))
var refused=false;let refusal=image {c in refused = !NativeCTFontVerticalPainter.draw(line:horizontal,context:c,anchor:.zero)}
let report:[String:Any]=["scope":"Hosted CoreText transport only: identical selected oriented run fonts/glyphs/rawpositions vsCTFrameDraw. Does not assert WK baseline equations or actual iOS paint closure.","cases":reports,"unsupportedHorizontalRefused":refused,"refusalCanvasUntouched":blank.1==refusal.1]
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("report.json"))


let validFill = reports.filter { ($0["strokePercent"] as! CGFloat) == 0 }.allSatisfy {
 ($0["accepted"] as! Bool) && ($0["changedRGBA"] as! Int) == 0 && ($0["stateRestored"] as! Bool)
}
let validStroke = reports.filter { ($0["strokePercent"] as! CGFloat) != 0 }.allSatisfy {
 !($0["accepted"] as! Bool) && ($0["refusalCanvasUntouched"] as! Bool) && ($0["stateRestored"] as! Bool)
}
print("Fill parity:",validFill,"stroke refusal:",validStroke,"horizontal refusal:",refused && blank.1==refusal.1)
if !validFill || !validStroke || !refused || blank.1 != refusal.1 { exit(1) }

 }
}
