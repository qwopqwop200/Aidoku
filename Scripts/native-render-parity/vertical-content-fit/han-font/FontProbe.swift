import CoreText
import CoreGraphics
import Foundation
@main struct Probe {
 static func main() throws {
  var result:[[String:Any]]=[]
  for name in ["PingFangSC-Semibold","PingFangSC-Regular","HiraginoSans-W8"] {
   let font=CTFontCreateWithName(name as CFString,20,nil)
   var chars=Array("天地玄黄宇宙洪荒".utf16),glyphs=[CGGlyph](repeating:0,count:chars.count)
   CTFontGetGlyphsForCharacters(font,&chars,&glyphs,chars.count)
   var horizontal=[CGSize](repeating:.zero,count:chars.count),vertical=horizontal
   CTFontGetAdvancesForGlyphs(font,.horizontal,&glyphs,&horizontal,chars.count)
   CTFontGetAdvancesForGlyphs(font,.vertical,&glyphs,&vertical,chars.count)
   let style=NativeTranslationTypography.Style(fontName:name,fontScript:"han",fontSize:20,vertical:true,lineHeight:24,strictLineBreak:true)
   let attr=NativeTranslationTypography.attributedString(text:"天",style:style)
   let line=CTLineCreateWithAttributedString(attr),runs=CTLineGetGlyphRuns(line)
   var fonts:[String]=[],advances:[[Double]]=[]
   for i in 0..<CFArrayGetCount(runs) {
    let run=unsafeBitCast(CFArrayGetValueAtIndex(runs,i),to:CTRun.self)
    let attributes=CTRunGetAttributes(run) as NSDictionary,f=attributes[kCTFontAttributeName] as! CTFont
    fonts.append(CTFontCopyPostScriptName(f) as String)
    var a=[CGSize](repeating:.zero,count:CTRunGetGlyphCount(run));CTRunGetAdvances(run,CFRange(location:0,length:0),&a)
    advances += a.map{[Double($0.width),Double($0.height)]}
   }
   result.append(["requested":name,"font":CTFontCopyPostScriptName(font) as String,"size":CTFontGetSize(font),"url":String(describing:CTFontCopyAttribute(font,kCTFontURLAttribute)),"glyphs":glyphs,
    "horizontal":horizontal.map{$0.width},"vertical":vertical.map{[$0.width,$0.height]},"runs":fonts,"runAdvances":advances,
    "line":CTLineGetTypographicBounds(line,nil,nil,nil),"traits":CTFontCopyTraits(font)])
  }
  let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted]);try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]));print(String(data:data,encoding:.utf8)!)
 }
}
