import AppKit
import Foundation
import CoreText
import CoreGraphics
import CryptoKit
let base=CTFontCreateWithName("PingFangSC-Semibold" as CFString,20,nil)
let line=CTLineCreateWithAttributedString(NSAttributedString(string:"天地",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):base,NSAttributedString.Key(kCTVerticalFormsAttributeName as String):true]))
let run=(CTLineGetGlyphRuns(line) as! [CTRun])[0],rf=(CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
let out=URL(fileURLWithPath:CommandLine.arguments[1]);let useCG=CommandLine.arguments.contains("--cg");var result:[[String:Any]]=[]
for (label,original) in [("base",base),("run",rf),("cgNamed", CTFontCreateWithGraphicsFont(CGFont("PingFangSC-Semibold" as CFString)!,20,nil,nil)),("nsNamed", NSFont(name:"PingFangSC-Semibold",size:20)! as CTFont)] {
 for optical in ["auto","none"] { for orientation in [CTFontOrientation.horizontal,CTFontOrientation.vertical] {
  let font=CTFontCreateCopyWithAttributes(original,20,nil,CTFontDescriptorCreateWithAttributes([kCTFontOpticalSizeAttribute:optical,kCTFontOrientationAttribute:orientation.rawValue] as CFDictionary))
  let name="\(useCG ? "cg" : "ct")-\(label)-\(optical)-\(orientation.rawValue)",cg=CTFontCopyGraphicsFont(font,nil)
  var chars=Array("天".utf16),glyphs=[CGGlyph](repeating:0,count:1),translation=[CGSize.zero],advance=[CGSize.zero]
  CTFontGetGlyphsForCharacters(font,&chars,&glyphs,1);CTFontGetVerticalTranslationsForGlyphs(font,&glyphs,&translation,1);CTFontGetAdvancesForGlyphs(font,.vertical,&glyphs,&advance,1)
  let path=CTFontCreatePathForGlyph(font,glyphs[0],nil)!,b=path.boundingBoxOfPath
  var commands:[[Any]]=[];path.applyWithBlock{e in let q=e.pointee,n: Int;switch q.type{case .moveToPoint,.addLineToPoint:n=1;case .addQuadCurveToPoint:n=2;case .addCurveToPoint:n=3;case .closeSubpath:n=0;@unknown default:n=0};commands.append([q.type.rawValue,(0..<n).map{[q.points[$0].x,q.points[$0].y]}])}
  let data=NSMutableData(),consumer=CGDataConsumer(data:data as CFMutableData)!;var media=CGRect(x:0,y:0,width:100,height:100);let ctx=CGContext(consumer:consumer,mediaBox:&media,nil)!
  ctx.beginPDFPage(nil);ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(media);ctx.setFillColor(CGColor(gray:0,alpha:1));var pos=CGPoint(x:40,y:40);if useCG {ctx.setFont(cg);ctx.setFontSize(20);ctx.showGlyphs(glyphs,at:[pos])} else {CTFontDrawGlyphs(font,&glyphs,&pos,1,ctx)};ctx.endPDFPage();ctx.closePDF();try (data as Data).write(to:out.appendingPathComponent(name+".pdf"))
  result.append(["name":name,"font":CTFontCopyPostScriptName(font) as String,"cgFont":cg.postScriptName! as String,"fontCount":CTFontGetGlyphCount(font),"cgCount":cg.numberOfGlyphs,"URL":String(describing:CTFontCopyAttribute(font,kCTFontURLAttribute)),"descriptor":String(describing:CTFontDescriptorCopyAttributes(CTFontCopyFontDescriptor(font))),"glyph":glyphs[0],"translation":[translation[0].width,translation[0].height],"advance":[advance[0].width,advance[0].height],"bounds":[b.minX,b.minY,b.width,b.height],"commands":commands])
 }}
}
try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent(useCG ? "cg-font-instance-report.json" : "ct-font-instance-report.json"))
