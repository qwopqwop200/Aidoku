import Foundation
import CoreText
let font=CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString,16,nil)
var glyphs:[CGGlyph]=[0],advance=[CGSize.zero]
CTFontGetAdvancesForGlyphs(font,.horizontal,&glyphs,&advance,1)
print("NOTDEF",advance[0].width)
for text in ["\u{000C}","가나다\u{000C}","가나다", "라마바"] {
 let line=CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font]))
 print("WIDTH",text.debugDescription,CTLineGetTypographicBounds(line,nil,nil,nil))
 let runs=CTLineGetGlyphRuns(line) as! [CTRun]
 for run in runs {
  var g=[CGGlyph](repeating:0,count:CTRunGetGlyphCount(run)),a=[CGSize](repeating:.zero,count:g.count)
  CTRunGetGlyphs(run,CFRange(location:0,length:0),&g);CTRunGetAdvances(run,CFRange(location:0,length:0),&a)
  let attrs=CTRunGetAttributes(run) as NSDictionary
  print("RUN",CTFontCopyPostScriptName(attrs[kCTFontAttributeName] as! CTFont),g,a.map(\.width))
 }
}
