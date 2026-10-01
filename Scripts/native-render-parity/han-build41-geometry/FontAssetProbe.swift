import CoreText
import CoreGraphics
import Foundation
let url=URL(fileURLWithPath:CommandLine.arguments[1])
let descriptors=CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as! [CTFontDescriptor]
var records:[[String:Any]]=[]
for d in descriptors {
 let n=CTFontDescriptorCopyAttribute(d,kCTFontNameAttribute) as? String ?? ""
 guard n=="PingFangSC-Semibold" else {continue}
 for size in [10.5,20,20.5] {
  let f=CTFontCreateWithFontDescriptor(d,size,nil)
  var c:Array<UniChar>=Array("天地玄黄宇宙洪荒".utf16),g=[CGGlyph](repeating:0,count:c.count),v=[CGSize](repeating:.zero,count:c.count),a=v
  CTFontGetGlyphsForCharacters(f,&c,&g,c.count);CTFontGetVerticalTranslationsForGlyphs(f,&g,&v,g.count);CTFontGetAdvancesForGlyphs(f,.vertical,&g,&a,g.count)
  let bounds=g.map {CTFontCreatePathForGlyph(f,$0,nil)!.boundingBoxOfPath}
  records.append(["font":CTFontCopyPostScriptName(f) as String,"size":CTFontGetSize(f),"glyphCount":CTFontGetGlyphCount(f),"URL":String(describing:CTFontCopyAttribute(f,kCTFontURLAttribute)),"ascent":CTFontGetAscent(f),"descent":CTFontGetDescent(f),"leading":CTFontGetLeading(f),"glyphs":g,"translations":v.map{[$0.width,$0.height]},"advances":a.map{[$0.width,$0.height]},"pathBounds":bounds.map{[$0.minX,$0.minY,$0.width,$0.height]},"scope":"Actual iOS font asset through public descriptor API, hosted by macOS CoreText; not simulator runtime or iOS CT implementation proof"])
 }
}
print(String(data:try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
