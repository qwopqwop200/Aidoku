import CoreText
import CoreGraphics
import Foundation
let base=CTFontCreateWithName("PingFangSC-Semibold" as CFString,20,nil)
var result:[[String:Any]]=[]
for optical in [0.0,12,20,24,100] {
 for fromFamily in [false,true] {
  let attrs:[CFString:Any]=fromFamily ? [kCTFontFamilyNameAttribute:"PingFang SC",kCTFontSizeAttribute:20,kCTFontTraitsAttribute:[kCTFontWeightTrait:0.3],kCTFontOpticalSizeAttribute:optical] : [kCTFontNameAttribute:"PingFangSC-Semibold",kCTFontOpticalSizeAttribute:optical]
  let desc=CTFontDescriptorCreateWithAttributes(attrs as CFDictionary),font=CTFontCreateWithFontDescriptor(desc,20,nil)
  let line=CTLineCreateWithAttributedString(NSAttributedString(string:"天",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font]))
  result.append(["optical":optical,"family":fromFamily,"name":CTFontCopyPostScriptName(font) as String,"width":CTLineGetTypographicBounds(line,nil,nil,nil),"variation":String(describing:CTFontCopyVariation(font)),"axes":String(describing:CTFontCopyVariationAxes(font))])
 }
}
let autoDescriptor=CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute:"PingFangSC-Semibold",kCTFontOpticalSizeAttribute:"auto"] as CFDictionary)
let autoFont=CTFontCreateWithFontDescriptor(autoDescriptor,20,nil)
var character:UniChar=0x5929,glyph:CGGlyph=0,advance=CGSize.zero
CTFontGetGlyphsForCharacters(autoFont,&character,&glyph,1)
CTFontGetAdvancesForGlyphs(autoFont,.horizontal,&glyph,&advance,1)
let autoLine=CTLineCreateWithAttributedString(NSAttributedString(string:"天",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):autoFont]))
result.append(["optical":"auto","family":false,"glyphAdvance":advance.width,"name":CTFontCopyPostScriptName(autoFont) as String,"width":CTLineGetTypographicBounds(autoLine,nil,nil,nil)])
for vertical in [false,true] {
 let attrs:[NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):autoFont,NSAttributedString.Key(kCTVerticalFormsAttributeName as String):vertical,NSAttributedString.Key(kCTKernAttributeName as String):-0.24]
 let line=CTLineCreateWithAttributedString(NSAttributedString(string:"天",attributes:attrs))
 result.append(["optical":"auto","verticalForms":vertical,"name":CTFontCopyPostScriptName(autoFont) as String,"width":CTLineGetTypographicBounds(line,nil,nil,nil)])
}
let data=try JSONSerialization.data(withJSONObject:result,options:.prettyPrinted);try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]));print(String(data:data,encoding:.utf8)!)
