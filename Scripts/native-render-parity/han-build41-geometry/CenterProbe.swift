import Foundation
import CoreText
import CoreGraphics
var records:[[String:Any]]=[]
for fontSize in [19.0,20] { for tracking in [-1.0,0,1] { for h in [154.0,155] {
 let font=CTFontCreateWithName("PingFangSC-Semibold" as CFString,fontSize,nil)
 var pitch:CGFloat=24,align=CTTextAlignment.center
 let p=withUnsafePointer(to:&pitch){ pp in withUnsafePointer(to:&align){ ap in
  var settings=[CTParagraphStyleSetting(spec:.minimumLineHeight,valueSize:MemoryLayout<CGFloat>.size,value:pp),CTParagraphStyleSetting(spec:.maximumLineHeight,valueSize:MemoryLayout<CGFloat>.size,value:pp),CTParagraphStyleSetting(spec:.alignment,valueSize:MemoryLayout<CTTextAlignment>.size,value:ap)]
  return CTParagraphStyleCreate(&settings,settings.count)
 }}
 let a=NSAttributedString(string:"天地玄黄宇宙洪荒",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTParagraphStyleAttributeName as String):p,NSAttributedString.Key(kCTVerticalFormsAttributeName as String):true,NSAttributedString.Key(kCTKernAttributeName as String):0,NSAttributedString.Key(kCTTrackingAttributeName as String):tracking])
 let f=CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(a),CFRange(location:0,length:0),CGPath(rect:CGRect(x:0,y:0,width:480,height:h),transform:nil),[kCTFrameProgressionAttributeName:CTFrameProgression.rightToLeft.rawValue] as CFDictionary)
 let lines=CTFrameGetLines(f) as! [CTLine];var origins=[CGPoint](repeating:.zero,count:lines.count);CTFrameGetLineOrigins(f,CFRange(location:0,length:0),&origins)
 records.append(["fontSize":fontSize,"tracking":tracking,"height":h,"primaryAscent":CTFontGetAscent(font),"primaryDescent":CTFontGetDescent(font),"lines":zip(lines,origins).map{ l,o ->[String:Any] in let adv=CTLineGetTypographicBounds(l,nil,nil,nil),r=CTLineGetStringRange(l);return ["range":[r.location,r.length],"advance":adv,"nativeTop":h-o.y,"sourceCenteredTop":max(0,h-adv)/2,"delta":max(0,h-adv)/2-(h-o.y)]}])
}}}
print(String(data:try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
