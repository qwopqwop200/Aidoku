import Foundation
import CoreText
let uiDescriptor = CTFontDescriptorCreateWithAttributes(["NSCTFontUIUsageAttribute": "CTFontBoldUsage"] as CFDictionary)
let uiFont = CTFontCreateWithFontDescriptor(uiDescriptor, 6, nil)
var rows: [[String:Any]] = []
for primary in ["HiraginoSans-W6", "HiraginoSans-W7"] {
    for cascade in ["default", "system-ui", "explicit-ui-hangul"] {
        let font: CTFont
        let original = CTFontCreateWithName(primary as CFString, 6, nil)
        if cascade == "default" { font = original }
        else {
            let descriptors: [CTFontDescriptor] = cascade == "system-ui" ? [CTFontCopyFontDescriptor(uiFont)] : [CTFontDescriptorCreateWithNameAndSize(".AppleSDGothicNeoI-Bold" as CFString,6)]
            let attrs = CTFontDescriptorCreateWithAttributes([kCTFontCascadeListAttribute:descriptors] as CFDictionary)
            font = CTFontCreateCopyWithAttributes(original, 6, nil, attrs)
        }
        for text in ["こんにちは世界", "안녕하세요, 세계", "여러분!", "日本語"] {
            let attributed = NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTKernAttributeName as String):-0.072])
            let line = CTLineCreateWithAttributedString(attributed)
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            var records:[[String:Any]] = []
            for run in runs {
                let f = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                let range = CTRunGetStringRange(run)
                records.append(["font":CTFontCopyPostScriptName(f) as String,"size":CTFontGetSize(f),"range":[range.location,range.length],"advance":CTRunGetTypographicBounds(run,CFRange(location:0,length:0),nil,nil,nil)])
            }
            rows.append(["primary":primary,"cascade":cascade,"text":text,"width":CTLineGetTypographicBounds(line,nil,nil,nil),"runs":records])
        }
    }
}
print(String(data:try JSONSerialization.data(withJSONObject:rows,options:[.sortedKeys]),encoding:.utf8)!)
