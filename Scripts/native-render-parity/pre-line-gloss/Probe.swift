import Foundation
import CoreText
let records=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
var output:[[String:Any]]=[]
for record in records {
    let a=record["input"] as! [String:Any], text=a["text"] as! String,font=a["font"] as! Double
    let ct=CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString,font,nil)
    let notdef=NativeVisibleControlGlyphs.formFeeds(text:"\u{000C}",font:ct)[0]
    func measure(_ text:String)->CGFloat {
        let value=NSMutableAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):ct])
        NativeVisibleControlGlyphs.apply(to:value)
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(value),nil,nil,nil))
    }
    let preserves=(a["whiteSpace"] as? String ?? "pre-line") == "pre-line"
    let rows=NativePreLineTextFlow.rows(text,width:a["width"] as! Double,
        overflowAnywhere:a["overflow"] as! String == "anywhere",preservesLineBreaks:preserves,
        balances:a["balances"] as? Bool ?? false,measure:measure)!
    var glyphRows:[[Int]]=[]
    for (index,row) in rows.enumerated() {
        let units=Array(row.text.utf16)
        for (offset,unit) in units.enumerated() where unit != 32 {
            glyphRows.append([row.sourceUTF16[offset].location,index])
        }
    }
    let normalized=NativePreLineTextFlow.normalize(text,preservesLineBreaks:preserves)
    output.append(["input":a,"normalized":normalized.text,"rows":rows.map(\.text),"height":rows.count*Int(a["pitch"] as! Double),"glyphRows":glyphRows,
        "sourceRows":rows.map{$0.sourceUTF16.map{[$0.location,$0.length]}},"visibleControlGlyph":0,"visibleControlAdvance":notdef.advance])
}
print(String(data:try JSONSerialization.data(withJSONObject:output),encoding:.utf8)!)
